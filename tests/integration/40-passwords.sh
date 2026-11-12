#!/bin/bash
# Spec 21 (O8-O13) on a throwaway host, as root, from the repo root, with fake Azure values. The admin login with the
# long test password, kept by a re-run without it; refusals that leave the app running; a camera whose password is the
# url test password, given through RTSP_USER / RTSP_PASSWORD and through the Add Camera form, connecting to a local
# fake camera (tests/integration/fake_camera.py) that streams ffmpeg's test pattern; and what the API shows.
set -uo pipefail
REPO=$PWD
fail=0
ok()   { echo "PASS  $1"; }
bad()  { echo "FAIL  $1"; fail=1; }
skip() { echo "SKIP  $1"; }
# within <seconds> <command...>: true once the command is, checking every 3 seconds
within() { local t=$1 i; shift; for ((i = 0; i < t; i += 3)); do "$@" && return 0; sleep 3; done; "$@"; }
# shellcheck source=tests/vectors.bash
source "$REPO/tests/vectors.bash"
load_vectors "$REPO/tests/password-vectors.txt"
LONG=${VEC[long]} CAMPW=${VEC[url]}
L=$(mktemp)
W=$(mktemp -d -p /var/tmp)
APP=/opt/object_detector_web_app
B=http://127.0.0.1:8080
show() { tail -6 "$L" | cut -c1-170; }
export AZURE_VISION_KEY=fake AZURE_VISION_ENDPOINT=https://fake.test AUTH_MODE=basic TLS_MODE=none TCP_PORT=8080
unset ADMIN_PASSWORD ADMIN_USER RTSP_URL RTSP_USER RTSP_PASSWORD

# code <user> <password> [path]: the HTTP status Caddy answers for that login (the header is built here, so the
# password is never on curl's command line)
code() {
  printf 'header = "Authorization: Basic %s"\n' "$(printf '%s' "$1:$2" | base64 -w0)" > "$W/curl.cfg"
  curl -s -m 5 -o /dev/null -w '%{http_code}' -K "$W/curl.cfg" "$B${3:-/}"
}
health() { [ "$(curl -s -m 3 -o /dev/null -w '%{http_code}' "$B/healthz")" = 200 ]; }
active() { for s in od-cameras od-web od-caddy; do systemctl is-active --quiet "$s" || return 1; done; }
# api <path> [curl args...]: the app's API on its socket, behind Caddy's login
api() { local p=$1; shift; curl -s -m 10 --unix-socket "$APP/web.sock" "$@" "http://x$p"; }
stored_url() { python3 -I -c 'import json,sys; print([c for c in json.load(open(sys.argv[1]))["cameras"] if c["id"]==sys.argv[2]][0]["url"])' "$APP/cameras.json" "$1" 2>/dev/null; }
live() { api /api/state | python3 -I -c 'import json,sys
c=[x for x in json.load(sys.stdin)["cameras"] if x["id"]==sys.argv[1]][0]
sys.exit(0 if c["connected"] and float(c["fps"] or 0) > 0 else 1)' "$1" 2>/dev/null; }

echo "=== The admin login with the long test password (O9)"
ADMIN_PASSWORD=$LONG ./deploy.sh install > "$L" 2>&1 && ok "install with the 128-character password" || { bad "install"; show; }
within 60 health && ok "/healthz answers, with no login" || bad "/healthz doesn't answer"
[ "$(code admin "$LONG")" = 200 ] && ok "log in with the long password" || bad "the long password gets $(code admin "$LONG")"
[ "$(code admin "${LONG}x")" = 401 ] && ok "a wrong password gets 401" || bad "a wrong password gets $(code admin "${LONG}x")"
[ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$B/")" = 401 ] && ok "no login gets 401" || bad "no login doesn't get 401"
grep -q '^    basic_auth argon2id {$' /etc/caddy/Caddyfile && ok "the Caddyfile names argon2id" || bad "the Caddyfile doesn't name argon2id"
[ "$(stat -c %a /etc/caddy/admin-login 2>/dev/null)" = 600 ] && ok "the stored login is mode 0600" || bad "the stored login: $(stat -c %a /etc/caddy/admin-login 2>&1)"
grep -qF -- "$LONG" "$L" && bad "the install printed the admin password" || ok "the install doesn't print the admin password"
[ "$(stat -c %a "$APP/azure.env")" = 600 ] && grep -q '^AZURE_VISION_KEY="fake"$' "$APP/azure.env" \
  && ok "azure.env is 0600, with its values in double quotes (O12)" || bad "azure.env: $(stat -c %a "$APP/azure.env")"

echo "=== A re-run without ADMIN_PASSWORD keeps the login (O11)"
sum=$(sha256sum < /etc/caddy/Caddyfile)
./deploy.sh install > "$L" 2>&1 && ok "a re-run without ADMIN_PASSWORD" || { bad "re-run"; show; }
within 60 health || true
[ "$(code admin "$LONG")" = 200 ] && ok "the long password still logs in" || bad "the long password gets $(code admin "$LONG") after the re-run"
[ "$(code admin changeme)" = 401 ] && ok "changeme doesn't" || bad "changeme logs in after a re-run"
[ "$(sha256sum < /etc/caddy/Caddyfile)" = "$sum" ] && ok "the Caddyfile is unchanged" || bad "the re-run changed the Caddyfile"
ADMIN_PASSWORD=$LONG ./deploy.sh install > "$L" 2>&1 && ok "a re-run with the same password" || { bad "re-run with the same password"; show; }
[ "$(sha256sum < /etc/caddy/Caddyfile)" = "$sum" ] && ok "the same password keeps the stored hash (Q5)" || bad "the same password changed the Caddyfile"

echo "=== Refusals happen before anything stops (O10, O11)"
if ADMIN_PASSWORD='' ./deploy.sh install > "$L" 2>&1; then bad "an empty ADMIN_PASSWORD exited 0"
elif grep -q "ADMIN_PASSWORD is set but empty" "$L" && active && health; then ok "an empty ADMIN_PASSWORD is refused, and the app keeps running"
else bad "the empty-password refusal is wrong"; show; fi
if ADMIN_USER='ad min' ./deploy.sh install > "$L" 2>&1; then bad "ADMIN_USER='ad min' exited 0"
elif grep -q "ADMIN_USER can only have" "$L" && active && health; then ok "a user name with a space is refused, and the app keeps running"
else bad "the user-name refusal is wrong"; show; fi
[ "$(code admin "$LONG")" = 200 ] && ok "the login is unchanged after the refusals" || bad "the login changed"

# The fake camera: Digest on /digest and Basic on /basic, user cam, the url test password. ffmpeg, which the install
# brings on Ubuntu, sends it its test pattern. Without ffmpeg (RHEL and Rocky have it only in RPM Fusion), the camera
# checks are skipped.
camera=0
if command -v ffmpeg >/dev/null 2>&1; then
  printf '%s' "$CAMPW" > "$W/campw"; : > "$W/cam.log"
  python3 -I "$REPO/tests/integration/fake_camera.py" 8554 9654 cam "$W/campw" "$W/cam.log" > "$W/cam.out" 2>&1 & cam_pid=$!
  ffmpeg -nostdin -loglevel error -re -f lavfi -i testsrc=size=640x360:rate=10 -c:v mjpeg -huffman default -pix_fmt yuvj420p -q:v 5 \
    -f rtp rtp://127.0.0.1:9654 > "$W/ffmpeg.out" 2>&1 & ffmpeg_pid=$!
  camera=1
else
  skip "the camera checks: no ffmpeg on this host to make the test stream"
fi
if [ "$camera" -eq 1 ]; then
  echo "=== A camera whose password is the url test password (O8, O13)"
  export RTSP_URL=rtsp://127.0.0.1:8554/digest RTSP_USER=cam RTSP_PASSWORD=$CAMPW
  ./deploy.sh install > "$L" 2>&1 && ok "a re-run with RTSP_URL, RTSP_USER and RTSP_PASSWORD" || { bad "re-run with the camera"; show; }
  within 60 health || true
  [ "$(stored_url cam1)" = 'rtsp://cam:Aa1%40%3A%2F%3F%23x@127.0.0.1:8554/digest' ] \
    && ok "RTSP_USER and RTSP_PASSWORD are percent-encoded into the URL" || bad "cam1's URL: $(stored_url cam1 | sed 's/:[^@]*@/:<hidden>@/')"
  within 90 live cam1 && ok "the camera connects under Digest auth, with frames" || bad "the camera isn't connected: $(api /api/state | head -c 300)"
  grep -q "digest ok" "$W/cam.log" && ok "the camera checked the login: Digest, exact" || bad "the camera saw no good Digest login ($(sort -u "$W/cam.log" | tr '\n' ' '))"
  printf '{"type":"rtsp","name":"<b>Form</b>","url":"rtsp://127.0.0.1:8554/basic","user":"cam","password":%s}' \
    "$(P=$CAMPW python3 -I -c 'import json,os; print(json.dumps(os.environ["P"]))')" > "$W/add.json"
  r=$(api /api/cameras -H 'Content-Type: application/json' --data-binary @"$W/add.json")
  id=$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["camera"]["id"])' "$r" 2>/dev/null)
  [ -n "$id" ] && ok "add a camera with the form's user and password ($id)" || bad "the form's camera wasn't added: ${r:0:200}"
  [[ "$r" == *'"url":"rtsp://cam:***@127.0.0.1:8554/basic"'* || "$r" == *'"url": "rtsp://cam:***@127.0.0.1:8554/basic"'* ]] \
    && ok "the answer shows its password as ***" || bad "the answer to the add: ${r:0:200}"
  [ "$(stored_url "$id")" = 'rtsp://cam:Aa1%40%3A%2F%3F%23x@127.0.0.1:8554/basic' ] \
    && ok "the app encodes it as deploy.sh does" || bad "$id's stored URL differs"
  within 90 live "$id" && ok "the form's camera connects under Basic auth, with frames" || bad "the form's camera isn't connected"
  grep -q "basic ok" "$W/cam.log" && ok "the camera checked the login: Basic, exact" || bad "the camera saw no good Basic login"
  list=$(api /api/cameras)
  [[ "$list" != *"Aa1%40"* && "$list" == *"cam:***@"* ]] && ok "GET /api/cameras shows passwords as ***" || bad "GET /api/cameras shows a password"
  [ "$(stat -c '%a %U' "$APP/cameras.json")" = "600 acvuser" ] && ok "cameras.json is 0600, owned by the app's user" || bad "cameras.json: $(stat -c '%a %U' "$APP/cameras.json")"
  ./deploy.sh install > "$L" 2>&1 && ok "a re-run keeps both cameras" || { bad "re-run with cameras"; show; }
  [ "$(code admin "$LONG")" = 200 ] && ok "the long password still logs in after the camera re-runs" || bad "the login changed"
  [ "$(stored_url "$id")" = 'rtsp://cam:Aa1%40%3A%2F%3F%23x@127.0.0.1:8554/basic' ] && [ -n "$(stored_url cam1)" ] \
    && ok "the form's camera and its password survive the re-run" || bad "the re-run lost a camera or its password"
  if RTSP_PASSWORD=$LONG ./deploy.sh install > "$L" 2>&1; then bad "a camera password over FFmpeg's limit exited 0"
  elif grep -q "FFmpeg reads at most 127" "$L" && ! grep -qF -- "$LONG" "$L" && active; then ok "a camera login over 127 bytes encoded is refused, by name, and the app keeps running"
  else bad "the 127-byte refusal is wrong"; show; fi
fi

PURGE=true ./deploy.sh uninstall > "$L" 2>&1 && ok "uninstall" || { bad "uninstall"; show; }
systemctl is-active --quiet od-web && bad "od-web is still running" || ok "od-web is gone"
[ ! -e /etc/caddy/admin-login ] && ok "the stored login is gone" || bad "/etc/caddy/admin-login is left"
if [ "$camera" -eq 1 ]; then kill "$cam_pid" "$ffmpeg_pid" 2>/dev/null; fi
echo "=== exit $fail"; exit $fail
