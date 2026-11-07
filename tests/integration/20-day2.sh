#!/bin/bash
# The Day-2 fixes (v1.1.0) on a throwaway host, as root, from the repo root, with fake Azure values. No camera needed.
# Runs after 10-lifecycle.sh, which leaves the host uninstalled. Each check here failed at v1.0.3.
set -uo pipefail
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
export AZURE_VISION_KEY=fake AZURE_VISION_ENDPOINT=https://fake.test AUTH_MODE=none TLS_MODE=none TCP_PORT=8080
L=$(mktemp)
APP=/opt/object_detector_web_app
show() { tail -6 "$L" | cut -c1-170; }
active() { for s in od-cameras od-web od-caddy; do systemctl is-active --quiet "$s" || return 1; done; }
cams() { python3 -c 'import json; print(" ".join(c["id"]+"="+(c.get("url") or c.get("device") or "") for c in json.load(open("'$APP'/cameras.json"))["cameras"]))'; }
healthy() { [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/healthz)" = 200 ]; }

echo "=== Install, then a UI camera survives a re-run (O2, O4)"
RTSP_URL=rtsp://192.168.1.250:554/stream ./deploy.sh install >"$L" 2>&1 && ok "install" || { bad "install"; show; }
grep -q "healthy" "$L" && ok "the install checks the app answers" || bad "no health check in the output"
[ "$(cams)" = "cam1=rtsp://192.168.1.250:554/stream" ] && ok "a camera at rtsp://192.168.1.250 is kept" || bad "cameras: $(cams)"
curl -s -m 10 --unix-socket "$APP/web.sock" -X POST -H 'Content-Type: application/json' \
  -d '{"type":"rtsp","name":"Added in UI","url":"rtsp://10.0.0.2/s"}' http://x/api/cameras >/dev/null
RTSP_URL=rtsp://192.168.1.250:554/stream ./deploy.sh install >"$L" 2>&1 && ok "a same-settings re-run" || { bad "re-run"; show; }
[ "$(cams)" = "cam1=rtsp://192.168.1.250:554/stream cam2=rtsp://10.0.0.2/s" ] && ok "the camera added in the UI is still there" || bad "cameras: $(cams)"
./deploy.sh install >"$L" 2>&1 && ok "a re-run with RTSP_URL cleared" || { bad "re-run with RTSP_URL cleared"; show; }
[ "$(cams)" = "cam2=rtsp://10.0.0.2/s" ] && ok "clearing RTSP_URL removes its camera, and keeps the UI's" || bad "cameras: $(cams)"
RTSP_URL=rtsp://10.0.0.1/s CAMERAS_RESET=true ./deploy.sh install >"$L" 2>&1 && ok "a re-run with CAMERAS_RESET=true" || { bad "CAMERAS_RESET"; show; }
[ "$(cams)" = "cam1=rtsp://10.0.0.1/s" ] && ok "CAMERAS_RESET=true rebuilds from the environment only" || bad "cameras: $(cams)"

echo "=== A local camera with only a device (O5)"
CAMERA_1_TYPE=local CAMERA_1_DEVICE=/dev/video0 CAMERA_1_NAME=Desk ./deploy.sh install >"$L" 2>&1 && ok "a re-run with a local camera" || { bad "local camera"; show; }
[[ " $(cams) " == *" cam1=/dev/video0 "* ]] && ok "the local camera is configured" || bad "cameras: $(cams)"

echo "=== Runtime settings on a re-run (O3, O7)"
AZURE_MONTHLY_BUDGET=999 AZURE_API_VERSION=v3.2 ./deploy.sh install >"$L" 2>&1 && ok "a re-run with a new budget and API version" || { bad "re-run with settings"; show; }
python3 -c 'import json; a=json.load(open("'$APP'/state/config.json"))["azure"]; assert a["monthly_budget"]==999 and a["api_version"]=="v3.2"' \
  && ok "the passed settings are applied" || bad "state/config.json didn't take them"
grep -q "Applied from the environment: AZURE_API_VERSION=v3.2, AZURE_MONTHLY_BUDGET=999" "$L" && ok "the run names what it changed" || bad "no note naming the changes"
./deploy.sh install >"$L" 2>&1 && ok "a re-run passing neither" || { bad "plain re-run"; show; }
grep -q "Azure: v3.2  |  budget 999 tx/mo" "$L" && ok "a setting not passed keeps its value, and the banner shows the file's" || { bad "the banner or file changed"; grep 'Azure:' "$L"; }

echo "=== A failing re-run leaves the app running (O1, O6)"
if TLS_MODE=bogus ./deploy.sh install >"$L" 2>&1; then bad "TLS_MODE=bogus exited 0"; else
  active && healthy && ok "a bad TLS_MODE is refused, and the app keeps running" || bad "a bad TLS_MODE took the app down"; fi
if CADDY_VERSION=9.9.9 ./deploy.sh install >"$L" 2>&1; then bad "a missing Caddy release exited 0"; else
  active && healthy && ok "a failed Caddy download leaves the app running" || bad "a failed Caddy download took the app down"; fi
if env -u FQDN TLS_MODE=auto ./deploy.sh install >"$L" 2>&1; then bad "TLS_MODE=auto with no FQDN exited 0"
elif grep -q "TLS_MODE=auto needs FQDN" "$L" && active; then ok "TLS_MODE=auto with no FQDN is refused, and the app keeps running"
else bad "the auto-TLS refusal is wrong"; show; fi

PURGE=true ./deploy.sh uninstall >"$L" 2>&1 && ok "uninstall" || { bad "uninstall"; show; }
systemctl is-active --quiet od-web && bad "od-web is still running" || ok "od-web is gone"
echo "=== exit $fail"; exit $fail
