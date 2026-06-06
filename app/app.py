"""
Object Detector Web - Flask app (served by gunicorn, 1 gevent worker).

Reads camera frames from per-camera POSIX shared memory written by
camera_supervisor.py, serves a live multi-camera grid UI, and runs Azure AI
Vision analysis (manual + interval auto-analyze) with a persistent free-tier
transaction budget guard. All inference features are toggle-able at runtime.
"""

import os
import io
import json
import time
import signal
import logging
import threading
import multiprocessing.shared_memory as shared_memory

from multiprocessing import resource_tracker

import cv2
import numpy as np
from flask import (Flask, Response, jsonify, request, send_from_directory)

import gevent

from analyzer import Analyzer, RateLimited, AnalyzerError, ALL_FEATURES

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s - %(levelname)s - %(message)s")
log = logging.getLogger("web")

APP_DIR = os.environ.get("APP_DIR", "/opt/object_detector_web_app")
STATE_DIR = os.environ.get("STATE_DIR", os.path.join(APP_DIR, "state"))
# The monthly transaction tally lives OUTSIDE APP_DIR so it survives a re-install
# or redeploy (a reinstall shouldn't zero your F0 usage for the month).
PERSIST_DIR = os.environ.get("PERSIST_DIR", "/var/lib/object_detector_web")
SNAP_DIR = os.path.join(APP_DIR, "snapshots")
CAMERAS_FILE = os.path.join(APP_DIR, "cameras.json")
CONFIG_FILE = os.path.join(STATE_DIR, "config.json")
BUDGET_FILE = os.path.join(PERSIST_DIR, "budget.json")
STATUS_FILE = os.path.join(STATE_DIR, "cameras_status.json")

FRAME_W, FRAME_H, FRAME_C = 1280, 720, 3
APP_VERSION = "1.0.3"

app = Flask(__name__)

# -------------------------------------------------------------- shared state
_cfg_lock = threading.Lock()
_budget_lock = threading.Lock()
_events_lock = threading.Lock()
_analysis = {}          # cam_id -> normalized result (+ _ts, _matched)
_events = []            # ring buffer of detection events
_last_auto = {}         # cam_id -> last auto-analyze epoch
_cooldown_until = 0.0   # 429 backoff
_analyzer = None
_analyzer_ver = None

_placeholder = b""
try:
    with open(os.path.join(APP_DIR, "static", "camera_unavailable.jpg"), "rb") as f:
        _placeholder = f.read()
except Exception as e:
    log.error("no placeholder image: %s", e)

DEFAULT_CONFIG = {
    "features": {"tags": True, "objects": True, "caption": True, "people": False,
                 "dense": False, "ocr": False, "brands": False, "color": False},
    "draw_boxes": True,
    "confidence": 0.5,
    "auto": {"enabled": False, "interval": 300},
    "keyword": {"enabled": False, "terms": [], "sound": True, "notify": False},
    "snapshots": {"enabled": False, "on_detection": False},
    "ocr_panel": True,
    "events": {"enabled": True, "max": 100},
    "azure": {"api_version": "v4", "monthly_budget": 4500, "budget_mode": "soft"},
}


# --------------------------------------------------------------- config I/O
def _deep_merge(base, override):
    out = dict(base)
    for k, v in (override or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = _deep_merge(out[k], v)
        else:
            out[k] = v
    return out


def load_config():
    try:
        with open(CONFIG_FILE) as f:
            return _deep_merge(DEFAULT_CONFIG, json.load(f))
    except Exception:
        return dict(DEFAULT_CONFIG)


def save_config(cfg):
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = CONFIG_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=2)
    os.replace(tmp, CONFIG_FILE)


def get_analyzer(cfg):
    """Build/rebuild the analyzer when the API version changes."""
    global _analyzer, _analyzer_ver
    ver = cfg["azure"]["api_version"]
    if _analyzer is None or _analyzer_ver != ver:
        _analyzer = Analyzer(os.environ.get("AZURE_VISION_ENDPOINT"),
                             os.environ.get("AZURE_VISION_KEY"), api_version=ver)
        _analyzer_ver = ver
    return _analyzer


# --------------------------------------------------------------- budget
def load_budget():
    # UTC month tag — Azure's F0 quota resets on the UTC calendar month, so align
    # the counter's auto-reset to UTC (not the host's local timezone).
    month = time.strftime("%Y-%m", time.gmtime())
    try:
        with open(BUDGET_FILE) as f:
            b = json.load(f)
        if b.get("month") != month:
            b = {"month": month, "count": 0}
    except Exception:
        b = {"month": month, "count": 0}
    return b


def save_budget(b):
    os.makedirs(os.path.dirname(BUDGET_FILE), exist_ok=True)
    tmp = BUDGET_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(b, f)
    os.replace(tmp, BUDGET_FILE)


def budget_add(tx):
    with _budget_lock:
        b = load_budget()
        b["count"] += tx
        save_budget(b)
        return b


# --------------------------------------------------------------- cameras / frames
def load_cameras():
    try:
        with open(CAMERAS_FILE) as f:
            return json.load(f).get("cameras", [])
    except Exception:
        return []


def save_cameras(cams):
    tmp = CAMERAS_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"cameras": cams}, f, indent=2)
    os.replace(tmp, CAMERAS_FILE)


def reload_supervisor():
    """Signal the camera supervisor (same user) to re-read cameras.json."""
    try:
        with open(os.path.join(STATE_DIR, "supervisor.pid")) as f:
            pid = int(f.read().strip())
        os.kill(pid, signal.SIGHUP)
        return True
    except Exception as e:
        log.warning("supervisor reload failed: %s", e)
        return False


def discover_usb_cameras():
    """Enumerate V4L2 capture devices via /sys (no device open, won't disturb capture)."""
    devs = []
    base = "/sys/class/video4linux"
    if os.path.isdir(base):
        for d in sorted(os.listdir(base)):
            name = d
            try:
                with open(os.path.join(base, d, "name")) as f:
                    name = f.read().strip()
            except Exception:
                pass
            devs.append({"device": "/dev/" + d, "name": name})
    return devs


def read_status():
    try:
        with open(STATUS_FILE) as f:
            return json.load(f)
    except Exception:
        return {}


def attach_shm(cam_id):
    """Attach to a supervisor-owned SHM segment WITHOUT registering it with this
    process's resource_tracker. Otherwise, when a gunicorn worker exits (e.g. a
    restart), the tracker would unlink the segment out from under the supervisor,
    breaking every reader. Only the supervisor (creator) should ever unlink."""
    shm = shared_memory.SharedMemory(name="od_frame_" + cam_id)
    try:
        resource_tracker.unregister(shm._name, "shared_memory")
    except Exception:
        pass
    return shm


def grab_frame(cam_id):
    """Attach SHM, copy the current frame, detach. Returns BGR ndarray or None."""
    try:
        shm = attach_shm(cam_id)
    except FileNotFoundError:
        return None
    try:
        arr = np.ndarray((FRAME_H, FRAME_W, FRAME_C), dtype=np.uint8, buffer=shm.buf)
        frame = arr.copy()
    finally:
        shm.close()
    if not frame.any():
        return None
    return frame


# --------------------------------------------------------------- analysis core
def _match_keywords(result, terms):
    if not terms:
        return []
    hay = []
    if result.get("caption"):
        hay.append(result["caption"]["text"])
    hay += [t["name"] for t in result.get("tags", [])]
    hay += [o["name"] for o in result.get("objects", [])]
    hay += [d["text"] for d in result.get("dense", [])]
    if result.get("ocr"):
        hay.append(result["ocr"]["text"])
    blob = " ".join(hay).lower()
    return [t for t in terms if t.strip() and t.strip().lower() in blob]


def _snap_meta(cam_id, result=None, terms=None):
    cam = next((c for c in load_cameras() if c.get("id") == cam_id), {})
    a = result if result is not None else (_analysis.get(cam_id) or {})
    return {
        "cam_id": cam_id,
        "cam_name": cam.get("name", cam_id),
        "ts": time.time(),
        "caption": (a.get("caption") or {}).get("text") if a.get("caption") else None,
        "tags": [t["name"] for t in a.get("tags", [])][:10],
        "objects": [o["name"] for o in a.get("objects", [])][:10],
        "terms": terms or [],
    }


def _save_snapshot(cam_id, frame, meta=None):
    os.makedirs(SNAP_DIR, exist_ok=True)
    fn = "%s_%s.jpg" % (cam_id, time.strftime("%Y%m%d-%H%M%S"))
    ok, jpg = cv2.imencode(".jpg", frame)
    if not ok:
        return None
    with open(os.path.join(SNAP_DIR, fn), "wb") as f:
        f.write(jpg.tobytes())
    with open(os.path.join(SNAP_DIR, fn[:-4] + ".json"), "w") as f:
        json.dump(meta or _snap_meta(cam_id), f)
    return fn


def _add_event(cam_id, cam_name, terms, snapshot, cfg):
    if not cfg["events"]["enabled"]:
        return
    with _events_lock:
        _events.append({"ts": time.time(), "cam_id": cam_id, "cam_name": cam_name,
                        "terms": terms, "snapshot": snapshot})
        del _events[: max(0, len(_events) - cfg["events"]["max"])]


def run_analysis(cam_id, cfg, source="manual"):
    """Analyze one camera's current frame. Returns (result_dict, error_str)."""
    global _cooldown_until
    cam = next((c for c in load_cameras() if c.get("id") == cam_id), None)
    if not cam:
        return None, "unknown camera"
    if time.time() < _cooldown_until:
        return None, "rate_limited"

    analyzer = get_analyzer(cfg)
    if not analyzer.configured:
        return None, "Azure credentials not configured"

    enabled = [f for f in ALL_FEATURES if cfg["features"].get(f)]
    applied = [f for f in enabled if f in analyzer.capabilities()]
    tx_cost = len(applied)
    if tx_cost == 0:
        return None, "no supported features enabled"

    # budget guard
    b = load_budget()
    budget = cfg["azure"]["monthly_budget"]
    over = (b["count"] + tx_cost) > budget
    if over and cfg["azure"]["budget_mode"] == "hard":
        return None, "budget_reached"
    if over and source == "auto":
        return None, "budget_reached"

    frame = grab_frame(cam_id)
    if frame is None:
        return None, "no frame (camera offline?)"
    ok, jpg = cv2.imencode(".jpg", frame)
    if not ok:
        return None, "encode failed"

    try:
        result = analyzer.analyze(jpg.tobytes(), enabled)
    except RateLimited:
        _cooldown_until = time.time() + 60
        return None, "rate_limited"
    except AnalyzerError as e:
        return None, str(e)
    except Exception as e:
        log.error("analyze error: %s", e)
        return None, "analysis failed"

    nb = budget_add(result["tx"])
    matched = _match_keywords(result, cfg["keyword"]["terms"]) if cfg["keyword"]["enabled"] else []
    snap = None
    if cfg["snapshots"]["enabled"] and (not cfg["snapshots"]["on_detection"] or matched):
        snap = _save_snapshot(cam_id, frame, _snap_meta(cam_id, result=result, terms=matched))
    if matched:
        _add_event(cam_id, cam.get("name", cam_id), matched, snap, cfg)

    result["_ts"] = time.time()
    result["_matched"] = matched
    result["_budget"] = nb
    result["_over_budget"] = over
    _analysis[cam_id] = result
    return result, None


# --------------------------------------------------------------- auto-analyze loop
def auto_loop():
    log.info("auto-analyze loop started")
    while True:
        try:
            cfg = load_config()
            if cfg["auto"]["enabled"]:
                interval = max(30, int(cfg["auto"]["interval"]))
                status = read_status()
                now = time.time()
                for cam in load_cameras():
                    cid = cam.get("id")
                    if not cam.get("enabled", True):
                        continue
                    if not status.get(cid, {}).get("connected"):
                        continue
                    if now - _last_auto.get(cid, 0) < interval:
                        continue
                    _last_auto[cid] = now
                    _, err = run_analysis(cid, cfg, source="auto")
                    if err in ("rate_limited", "budget_reached"):
                        log.warning("auto-analyze paused: %s", err)
                        break
        except Exception as e:
            log.error("auto loop: %s", e)
        gevent.sleep(5)


# --------------------------------------------------------------- routes
@app.route("/")
def index():
    return send_from_directory(os.path.join(APP_DIR, "templates"), "index.html")


@app.route("/healthz")
def healthz():
    return jsonify({"status": "ok", "version": APP_VERSION})


@app.route("/feed/<cam_id>")
def feed(cam_id):
    def gen():
        shm = None
        while True:
            frame_bytes = None
            try:
                if shm is None:
                    shm = attach_shm(cam_id)
                arr = np.ndarray((FRAME_H, FRAME_W, FRAME_C), dtype=np.uint8, buffer=shm.buf)
                connected = read_status().get(cam_id, {}).get("connected")
                frame = arr.copy()
                if connected and frame.any():
                    ok, jpg = cv2.imencode(".jpg", frame)
                    if ok:
                        frame_bytes = jpg.tobytes()
            except FileNotFoundError:
                if shm:
                    shm.close()
                    shm = None
            except Exception as e:
                log.error("feed %s: %s", cam_id, e)
            if frame_bytes is None:
                frame_bytes = _placeholder
            yield (b"--frame\r\nContent-Type: image/jpeg\r\n\r\n" + frame_bytes + b"\r\n")
            time.sleep(0.04)
    return Response(gen(), mimetype="multipart/x-mixed-replace; boundary=frame")


@app.route("/api/state")
def api_state():
    cfg = load_config()
    status = read_status()
    cams = []
    for c in load_cameras():
        cid = c.get("id")
        st = status.get(cid, {})
        cams.append({"id": cid, "name": c.get("name", cid), "type": c.get("type", "rtsp"),
                     "enabled": c.get("enabled", True),
                     "connected": bool(st.get("connected")), "fps": st.get("fps", 0)})
    return jsonify({
        "version": APP_VERSION,
        "cameras": cams,
        "config": cfg,
        "budget": load_budget(),
        "capabilities": get_analyzer(cfg).capabilities(),
        "all_features": ALL_FEATURES,
        "azure_configured": get_analyzer(cfg).configured,
        "cooldown": max(0, int(_cooldown_until - time.time())),
    })


@app.route("/api/cameras", methods=["GET", "POST"])
def api_cameras():
    if request.method == "GET":
        return jsonify(load_cameras())
    data = request.get_json(force=True, silent=True) or {}
    ctype = data.get("type", "rtsp")
    name = (data.get("name") or "").strip()
    cams = load_cameras()
    ids = {c.get("id") for c in cams}
    if ctype == "local":
        device = (data.get("device") or "/dev/video0").strip()
        digits = "".join(ch for ch in device if ch.isdigit()) or "0"
        cid = base = "usb" + digits
        n = 0
        while cid in ids:
            n += 1
            cid = base + "_" + str(n)
        cam = {"id": cid, "name": name or ("USB " + device), "type": "local",
               "device": device, "enabled": True}
    else:
        url = (data.get("url") or "").strip()
        if not url.startswith("rtsp://") and not url.startswith("http"):
            return jsonify({"status": "error", "message": "RTSP/HTTP URL required"}), 400
        n = 1
        while ("cam%d" % n) in ids:
            n += 1
        cid = "cam%d" % n
        cam = {"id": cid, "name": name or ("Camera %d" % n), "type": "rtsp",
               "url": url, "enabled": True}
    cams.append(cam)
    save_cameras(cams)
    reload_supervisor()
    return jsonify({"status": "ok", "camera": cam, "cameras": cams})


@app.route("/api/cameras/<cid>", methods=["DELETE"])
def api_camera_delete(cid):
    cams = [c for c in load_cameras() if c.get("id") != cid]
    save_cameras(cams)
    reload_supervisor()
    _analysis.pop(cid, None)
    return jsonify({"status": "ok", "cameras": cams})


@app.route("/api/discover_usb")
def api_discover_usb():
    return jsonify(discover_usb_cameras())


@app.route("/api/analysis/<cam_id>")
def api_analysis(cam_id):
    return jsonify(_analysis.get(cam_id) or {})


@app.route("/api/analyze/<cam_id>", methods=["POST"])
def api_analyze(cam_id):
    cfg = load_config()
    result, err = run_analysis(cam_id, cfg, source="manual")
    if err:
        return jsonify({"status": "error", "message": err}), 429 if err == "rate_limited" else 400
    return jsonify({"status": "ok", "result": result})


@app.route("/api/analyze_all", methods=["POST"])
def api_analyze_all():
    cfg = load_config()
    out = {}
    for c in load_cameras():
        cid = c.get("id")
        if not c.get("enabled", True):
            continue
        _, err = run_analysis(cid, cfg, source="manual")
        out[cid] = err or "ok"
    return jsonify({"status": "ok", "results": out})


@app.route("/api/config", methods=["GET", "POST"])
def api_config():
    if request.method == "GET":
        return jsonify(load_config())
    with _cfg_lock:
        cfg = _deep_merge(load_config(), request.get_json(force=True, silent=True) or {})
        # clamp
        cfg["confidence"] = max(0.0, min(1.0, float(cfg["confidence"])))
        cfg["auto"]["interval"] = max(30, int(cfg["auto"]["interval"]))
        cfg["azure"]["monthly_budget"] = max(0, int(cfg["azure"]["monthly_budget"]))
        if cfg["azure"]["api_version"] not in ("v4", "v3.2"):
            cfg["azure"]["api_version"] = "v4"
        save_config(cfg)
    return jsonify({"status": "ok", "config": cfg})


@app.route("/api/events")
def api_events():
    with _events_lock:
        return jsonify(list(reversed(_events)))


@app.route("/api/snapshot/<cam_id>", methods=["POST"])
def api_snapshot(cam_id):
    frame = grab_frame(cam_id)
    if frame is None:
        return jsonify({"status": "error", "message": "no frame"}), 400
    fn = _save_snapshot(cam_id, frame)
    return jsonify({"status": "ok", "file": fn})


@app.route("/api/snapshots")
def api_snapshots():
    items = []
    if os.path.isdir(SNAP_DIR):
        for fn in os.listdir(SNAP_DIR):
            if not fn.endswith(".jpg"):
                continue
            path = os.path.join(SNAP_DIR, fn)
            meta = {}
            mp = path[:-4] + ".json"
            if os.path.exists(mp):
                try:
                    with open(mp) as f:
                        meta = json.load(f)
                except Exception:
                    pass
            try:
                st = os.stat(path)
            except OSError:
                continue
            items.append({"file": fn, "url": "/snapshots/" + fn,
                          "size": st.st_size, "mtime": st.st_mtime, "meta": meta})
    items.sort(key=lambda x: x["mtime"], reverse=True)
    return jsonify(items)


@app.route("/snapshots/<path:fn>")
def snapshots(fn):
    return send_from_directory(SNAP_DIR, fn)


# Start the background auto-analyze greenlet once, at import time (1 worker).
_auto_started = False


def _start_auto():
    global _auto_started
    if not _auto_started:
        _auto_started = True
        gevent.spawn(auto_loop)


_start_auto()


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8000)
