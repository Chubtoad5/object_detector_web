"""A fake RTSP camera with a login, for the integration tests (spec 21, O8). Standard library only.

It asks for Digest auth on rtsp://127.0.0.1:<port>/digest and for Basic auth on /basic, and checks each login against
the user and the password it was given. A client that logs in gets the MJPEG stream that ffmpeg sends it as RTP on UDP
<rtp port> (the test starts that ffmpeg), relayed inside the RTSP connection (RTP over TCP, as the app asks for). Every
login it checks goes to the log as "basic ok", "digest ok", "basic refused" or "digest refused", never with the password.

Usage: fake_camera.py <port> <rtp port> <user> <password file> <log file>
The password file holds the password exactly, with no newline after it.
"""
import base64
import hashlib
import socket
import socketserver
import sys
import threading
import urllib.request

PORT, RTP_PORT, USER, PASSWORD_FILE, LOG = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
with open(PASSWORD_FILE, "rb") as f:
    PASSWORD = f.read().decode("utf-8")
REALM, NONCE = "fakecam", "5f2b8a19c3d4"
SDP = ("v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=fake camera\r\nc=IN IP4 0.0.0.0\r\nt=0 0\r\n"
       "m=video 0 RTP/AVP 26\r\na=control:track1\r\n")
SESSION = "4f1e2d3c"
players = set()
players_lock = threading.Lock()
log_lock = threading.Lock()


def log(line):
    with log_lock, open(LOG, "a") as f:
        f.write(line + "\n")


def md5(s):
    return hashlib.md5(s.encode("utf-8")).hexdigest()


def logged_in(method, path, headers):
    scheme, _, rest = headers.get("authorization", "").partition(" ")
    if path.startswith("/basic"):
        if scheme.lower() != "basic":
            return False
        try:
            got = base64.b64decode(rest.strip()).decode("utf-8")
        except ValueError:
            got = None
        ok = got == USER + ":" + PASSWORD
        log("basic " + ("ok" if ok else "refused"))
        return ok
    if scheme.lower() != "digest":
        return False
    fields = {}
    for item in urllib.request.parse_http_list(rest):
        k, _, v = item.partition("=")
        fields[k.strip().lower()] = v.strip().strip('"')
    ha1 = md5("%s:%s:%s" % (USER, REALM, PASSWORD))
    ha2 = md5("%s:%s" % (method, fields.get("uri", "")))
    ok = (fields.get("username") == USER and fields.get("nonce") == NONCE
          and fields.get("response") == md5("%s:%s:%s" % (ha1, NONCE, ha2)))
    log("digest " + ("ok" if ok else "refused"))
    return ok


class Camera(socketserver.StreamRequestHandler):
    def setup(self):
        super().setup()
        self.send_lock = threading.Lock()

    def send(self, data):
        with self.send_lock:
            self.wfile.write(data)
            self.wfile.flush()

    def reply(self, cseq, status, headers=(), body=""):
        out = "RTSP/1.0 %s\r\nCSeq: %s\r\n" % (status, cseq)
        for h in headers:
            out += h + "\r\n"
        if body:
            out += "Content-Length: %d\r\n" % len(body.encode())
        self.send((out + "\r\n" + body).encode())

    def read_request(self):
        """(method, uri, headers), skipping the RTCP the client sends inside the connection; None at the end."""
        while True:
            first = self.rfile.read(1)
            if not first:
                return None
            if first == b"$":
                head = self.rfile.read(3)
                if len(head) < 3:
                    return None
                self.rfile.read(int.from_bytes(head[1:3], "big"))
                continue
            line = (first + self.rfile.readline()).decode("utf-8", "replace").strip()
            if line:
                break
        method, uri = (line.split(" ") + ["", ""])[:2]
        headers = {}
        while True:
            h = self.rfile.readline().decode("utf-8", "replace").rstrip("\r\n")
            if not h:
                break
            k, _, v = h.partition(":")
            headers[k.strip().lower()] = v.strip()
        if int(headers.get("content-length", "0") or 0):
            self.rfile.read(int(headers["content-length"]))
        return method, uri, headers

    def handle(self):
        try:
            while True:
                req = self.read_request()
                if req is None:
                    break
                method, uri, h = req
                cseq = h.get("cseq", "0")
                path = "/" + uri.split("://", 1)[-1].split("/", 1)[-1] if "://" in uri else uri
                if method == "OPTIONS":
                    self.reply(cseq, "200 OK", ["Public: OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN, GET_PARAMETER"])
                elif method in ("GET_PARAMETER", "SET_PARAMETER"):
                    self.reply(cseq, "200 OK", ["Session: " + SESSION])
                elif method == "TEARDOWN":
                    self.reply(cseq, "200 OK", ["Session: " + SESSION])
                    break
                elif not logged_in(method, path, h):
                    challenge = ('Basic realm="%s"' % REALM if path.startswith("/basic")
                                 else 'Digest realm="%s", nonce="%s"' % (REALM, NONCE))
                    self.reply(cseq, "401 Unauthorized", ["WWW-Authenticate: " + challenge])
                elif method == "DESCRIBE":
                    base = uri.split("?", 1)[0].rstrip("/") + "/"
                    self.reply(cseq, "200 OK", ["Content-Base: " + base, "Content-Type: application/sdp"], SDP)
                elif method == "SETUP":
                    if "TCP" not in h.get("transport", "").upper():
                        self.reply(cseq, "461 Unsupported Transport")
                        continue
                    self.reply(cseq, "200 OK", ["Transport: RTP/AVP/TCP;unicast;interleaved=0-1",
                                                "Session: %s;timeout=60" % SESSION])
                elif method == "PLAY":
                    self.reply(cseq, "200 OK", ["Session: " + SESSION, "Range: npt=0.000-"])
                    with players_lock:
                        players.add(self)
                else:
                    self.reply(cseq, "501 Not Implemented")
        except OSError:
            pass
        finally:
            with players_lock:
                players.discard(self)


def relay():
    """Each RTP packet ffmpeg sends, to every client that is playing, framed for RTP over TCP (channel 0)."""
    rtp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rtp.bind(("127.0.0.1", RTP_PORT))
    rtcp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)   # ffmpeg's RTCP, read and dropped
    rtcp.bind(("127.0.0.1", RTP_PORT + 1))
    threading.Thread(target=lambda: [rtcp.recv(2048) for _ in iter(int, 1)], daemon=True).start()
    while True:
        packet = rtp.recv(65536)
        frame = b"$\x00" + len(packet).to_bytes(2, "big") + packet
        with players_lock:
            targets = list(players)
        for p in targets:
            try:
                p.send(frame)
            except OSError:
                with players_lock:
                    players.discard(p)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


threading.Thread(target=relay, daemon=True).start()
Server(("127.0.0.1", PORT), Camera).serve_forever()
