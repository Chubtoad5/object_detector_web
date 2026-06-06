"""
Multi-camera supervisor.

Runs one capture thread per enabled camera (real OS threads - NOT gevent, so a
blocking cv2 read on one camera never stalls the others). Each thread writes the
latest 1280x720 BGR frame into its own POSIX shared-memory buffer named
`od_frame_<id>`, which the web app reads. Camera connection state is published to
`<STATE_DIR>/cameras_status.json`.

Cameras are defined in `<APP_DIR>/cameras.json`:
{ "cameras": [ {"id","name","type":"rtsp|local","url"|"device","enabled"} ] }

SIGHUP reloads cameras.json (start/stop threads to match). SIGTERM/SIGINT cleans
up shared memory.
"""

import os
import sys
import json
import time
import signal
import logging
import threading
import multiprocessing.shared_memory as shared_memory

import cv2
import numpy as np

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s - %(levelname)s - %(message)s")
log = logging.getLogger("supervisor")

APP_DIR = os.environ.get("APP_DIR", "/opt/object_detector_web_app")
STATE_DIR = os.environ.get("STATE_DIR", os.path.join(APP_DIR, "state"))
CAMERAS_FILE = os.path.join(APP_DIR, "cameras.json")
STATUS_FILE = os.path.join(STATE_DIR, "cameras_status.json")

FRAME_W, FRAME_H, FRAME_C = 1280, 720, 3
BUF_SIZE = FRAME_W * FRAME_H * FRAME_C

# Be patient with RTSP streams; prefer TCP transport.
os.environ.setdefault("OPENCV_FFMPEG_CAPTURE_OPTIONS",
                      "rtsp_transport;tcp|stimeout;60000000")

_status = {}
_status_lock = threading.Lock()
_stop = threading.Event()
_workers = {}  # id -> CameraWorker


def shm_name(cam_id):
    return "od_frame_" + cam_id


class CameraWorker(threading.Thread):
    def __init__(self, cam):
        super().__init__(daemon=True)
        self.cam = cam
        self.id = cam["id"]
        self.stop_flag = threading.Event()
        self.shm = None
        self.arr = None

    def _open_shm(self):
        name = shm_name(self.id)
        try:
            self.shm = shared_memory.SharedMemory(name=name, create=True, size=BUF_SIZE)
        except FileExistsError:
            self.shm = shared_memory.SharedMemory(name=name)
        self.arr = np.ndarray((FRAME_H, FRAME_W, FRAME_C), dtype=np.uint8, buffer=self.shm.buf)

    def _open_capture(self):
        ctype = self.cam.get("type", "rtsp")
        if ctype == "local":
            dev = self.cam.get("device", "/dev/video0")
            idx = int(dev.replace("/dev/video", "")) if dev.startswith("/dev/video") else 0
            return cv2.VideoCapture(idx, cv2.CAP_V4L2)
        return cv2.VideoCapture(self.cam.get("url", ""), cv2.CAP_FFMPEG)

    def _set_status(self, **kw):
        with _status_lock:
            s = _status.setdefault(self.id, {})
            s.update(name=self.cam.get("name", self.id), type=self.cam.get("type", "rtsp"))
            s.update(kw)

    def run(self):
        self._open_shm()
        self._set_status(connected=False, width=FRAME_W, height=FRAME_H, fps=0.0)
        while not self.stop_flag.is_set() and not _stop.is_set():
            cap = None
            try:
                log.info("[%s] connecting (%s)", self.id, self.cam.get("type"))
                cap = self._open_capture()
                if not cap or not cap.isOpened():
                    raise IOError("failed to open capture")
                log.info("[%s] connected, capturing frames", self.id)
                self._set_status(connected=True)
                last, frames = time.time(), 0
                while not self.stop_flag.is_set() and not _stop.is_set():
                    ok, frame = cap.read()
                    if not ok or frame is None:
                        log.warning("[%s] lost frame; reconnecting", self.id)
                        break
                    if frame.shape[0] != FRAME_H or frame.shape[1] != FRAME_W:
                        frame = cv2.resize(frame, (FRAME_W, FRAME_H))
                    self.arr[:] = frame[:]
                    frames += 1
                    now = time.time()
                    if now - last >= 2.0:
                        self._set_status(connected=True, fps=round(frames / (now - last), 1))
                        last, frames = now, 0
                    time.sleep(0.01)
            except Exception as e:
                log.error("[%s] %s", self.id, e)
            finally:
                if cap:
                    cap.release()
                self._set_status(connected=False, fps=0.0)
            if not self.stop_flag.is_set() and not _stop.is_set():
                time.sleep(5)  # backoff before reconnect
        self._cleanup()

    def _cleanup(self):
        try:
            if self.shm:
                self.shm.close()
                self.shm.unlink()
        except FileNotFoundError:
            pass
        except Exception as e:
            log.error("[%s] cleanup: %s", self.id, e)

    def stop(self):
        self.stop_flag.set()


def load_cameras():
    try:
        with open(CAMERAS_FILE) as f:
            data = json.load(f)
        return [c for c in data.get("cameras", []) if c.get("enabled", True) and c.get("id")]
    except Exception as e:
        log.error("could not read %s: %s", CAMERAS_FILE, e)
        return []


def reconcile():
    """Start/stop worker threads so they match the enabled cameras in cameras.json."""
    cams = {c["id"]: c for c in load_cameras()}
    for cid in list(_workers):
        if cid not in cams:
            log.info("stopping removed camera %s", cid)
            _workers[cid].stop()
            del _workers[cid]
    for cid, cam in cams.items():
        if cid not in _workers:
            log.info("starting camera %s (%s)", cid, cam.get("name"))
            w = CameraWorker(cam)
            _workers[cid] = w
            w.start()
    with _status_lock:
        for cid in list(_status):
            if cid not in cams:
                del _status[cid]


def write_status():
    with _status_lock:
        snapshot = json.dumps(_status)
    tmp = STATUS_FILE + ".tmp"
    with open(tmp, "w") as f:
        f.write(snapshot)
    os.replace(tmp, STATUS_FILE)


def handle_sighup(signum, frame):
    log.info("SIGHUP - reloading cameras.json")
    reconcile()


def handle_term(signum, frame):
    log.info("signal %s - shutting down", signum)
    _stop.set()


def main():
    os.makedirs(STATE_DIR, exist_ok=True)
    try:
        with open(os.path.join(STATE_DIR, "supervisor.pid"), "w") as f:
            f.write(str(os.getpid()))
    except Exception as e:
        log.error("could not write pidfile: %s", e)
    signal.signal(signal.SIGHUP, handle_sighup)
    signal.signal(signal.SIGTERM, handle_term)
    signal.signal(signal.SIGINT, handle_term)
    reconcile()
    if not _workers:
        log.warning("no enabled cameras configured")
    while not _stop.is_set():
        write_status()
        _stop.wait(2.0)
    for w in _workers.values():
        w.stop()
    for w in _workers.values():
        w.join(timeout=5)
    write_status()
    log.info("supervisor stopped")
    sys.exit(0)


if __name__ == "__main__":
    main()
