#!/bin/bash
# The real installer on a throwaway host, as root, from the repo root, with fake Azure values. No camera needed.
set -uo pipefail
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
export AZURE_VISION_KEY=fake AZURE_VISION_ENDPOINT=https://fake.test AUTH_MODE=none TLS_MODE=none TCP_PORT=8080 RTSP_URL=rtsp://10.0.0.1/s
L=$(mktemp)
./deploy.sh install >"$L" 2>&1 && ok "install" || { bad "install"; tail -6 "$L" | cut -c1-170; }
for s in od-cameras od-web od-caddy; do systemctl is-active --quiet "$s" && ok "$s is active" || bad "$s isn't active"; done
for _ in $(seq 1 20); do [ "$(curl -s -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/healthz)" = 200 ] && break; sleep 2; done
[ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/healthz)" = 200 ] && ok "/healthz answers" || bad "/healthz doesn't answer"
python3 -c 'import json; c=json.load(open("/opt/object_detector_web_app/cameras.json"))["cameras"]; assert c[0]["url"]=="rtsp://10.0.0.1/s"' && ok "cameras.json has the camera" || bad "cameras.json is wrong"
PURGE=true ./deploy.sh uninstall >"$L" 2>&1 && ok "uninstall" || { bad "uninstall"; tail -6 "$L" | cut -c1-170; }
systemctl is-active --quiet od-web && bad "od-web is still running" || ok "od-web is gone"
echo "=== exit $fail"; exit $fail
