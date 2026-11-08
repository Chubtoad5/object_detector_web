#!/bin/bash
# A real camera's frames reach the page, on a throwaway host, as root, from the repo root (spec 09's C5, in the
# chubtoad-automation project). The stream comes from CI: CI_CAMERA_RTSP_URL, from the runner's own config, never from
# this repo. Without it, the test is skipped. Fake Azure values, as the other tests use: no analysis runs.
set -uo pipefail
REPO=$PWD
fail=0
ok()   { echo "PASS  $1"; }
bad()  { echo "FAIL  $1"; fail=1; }
skip() { echo "SKIP  $1"; }
# within <seconds> <command...>: true once the command is, checking every 3 seconds
within() { local t=$1 i; shift; for ((i = 0; i < t; i += 3)); do "$@" && return 0; sleep 3; done; "$@"; }
if [ -z "${CI_CAMERA_RTSP_URL:-}" ]; then skip "the camera test: no CI_CAMERA_RTSP_URL (CI's runner gives one)"; echo "=== exit 0"; exit 0; fi
L=$(mktemp)
B=http://127.0.0.1:8080
export AZURE_VISION_KEY=fake AZURE_VISION_ENDPOINT=https://fake.test AUTH_MODE=none TLS_MODE=none TCP_PORT=8080 RTSP_URL=$CI_CAMERA_RTSP_URL
./deploy.sh install > "$L" 2>&1 && ok "install with the camera's stream" || { bad "install"; tail -6 "$L" | sed "s#$CI_CAMERA_RTSP_URL#<the camera>#g" | cut -c1-170; }
health() { [ "$(curl -s -m 3 -o /dev/null -w '%{http_code}' "$B/healthz")" = 200 ]; }
within 60 health && ok "/healthz answers" || bad "/healthz doesn't answer"
PY=/opt/object_detector_web_app/venv/bin/python3; [ -x "$PY" ] || PY=python3
state() { curl -s -m 5 "$B/api/state"; }
cam=$(state | "$PY" -c 'import json,sys; c=json.load(sys.stdin)["cameras"]; print(c[0]["id"] if c else "")' 2>/dev/null)
[ -n "$cam" ] && ok "the app has the camera ($cam)" || bad "the app lists no camera"
live() { state | "$PY" -c 'import json,sys
c=[x for x in json.load(sys.stdin)["cameras"] if x["id"]==sys.argv[1]][0]
sys.exit(0 if c["connected"] and float(c["fps"] or 0) > 0 else 1)' "$cam" 2>/dev/null; }
within 90 live && ok "the camera is connected, with frames per second above 0" || bad "the camera isn't connected: $(state | head -c 300)"
# Two frames from the page's MJPEG feed, a few seconds apart: each a JPEG that isn't the placeholder, and not the same.
frame() { curl -s -m 4 "$B/feed/$cam" 2>/dev/null | "$PY" -c 'import sys
d=sys.stdin.buffer.read(); s=d.find(b"\xff\xd8"); e=d.find(b"\xff\xd9", s)
sys.stdout.buffer.write(d[s:e+2] if s >= 0 and e > s else b"")' > "$1"; }
frame /var/tmp/c5-a.jpg; sleep 3; frame /var/tmp/c5-b.jpg
[ -s /var/tmp/c5-a.jpg ] && [ "$(head -c 2 /var/tmp/c5-a.jpg | od -An -tx1 | tr -d ' ')" = ffd8 ] && ok "the page's feed sends JPEG frames" || bad "no JPEG frame from /feed/$cam"
cmp -s /var/tmp/c5-a.jpg "$REPO/camera_unavailable.jpg" && bad "the frame is the camera-unavailable placeholder" || ok "the frame isn't the placeholder"
cmp -s /var/tmp/c5-a.jpg /var/tmp/c5-b.jpg && bad "two frames 3 s apart are identical: the video isn't live" || ok "two frames 3 s apart differ: the video is live"
c=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST "$B/api/snapshot/$cam"); [[ "$c" =~ ^2 ]] && ok "take a snapshot" || bad "the snapshot got $c"
grep -q '\.jpg' <<< "$(curl -s -m 5 "$B/api/snapshots")" && ok "the snapshot is listed" || bad "no snapshot listed"
rm -f /var/tmp/c5-a.jpg /var/tmp/c5-b.jpg
PURGE=true ./deploy.sh uninstall > "$L" 2>&1 && ok "uninstall" || { bad "uninstall"; tail -6 "$L" | cut -c1-170; }
systemctl is-active --quiet od-web && bad "od-web is still running" || ok "od-web is gone"
echo "=== exit $fail"; exit $fail
