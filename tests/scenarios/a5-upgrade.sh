#!/bin/bash
# A5: deploy the last release (its source archive from GitHub), add a camera and change a setting through the UI's API,
# then deploy the commit under test over it. The UI camera, the setting and the persisted budget survive, as the README's
# re-run sections say.
set -uo pipefail
REPO=$PWD
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
within() { local t=$1 i; shift; for ((i = 0; i < t; i += 3)); do "$@" && return 0; sleep 3; done; "$@"; }
W=$(mktemp -d -p /var/tmp); cd "$W" || exit 1
R=object_detector_web
old=$(curl -sI -m 20 "https://github.com/Chubtoad5/$R/releases/latest" | tr -d '\r' | sed -n 's#^[Ll]ocation: .*/tag/##p')
[[ "$old" =~ ^v[0-9]+(\.[0-9]+)+$ ]] && ok "the last release is $old" || { bad "couldn't find the last release: '$old'"; echo "=== exit 1"; exit 1; }
mkdir old
curl -sfL -m 180 "https://github.com/Chubtoad5/$R/archive/refs/tags/$old.tar.gz" | tar -xz -C old --strip-components=1 && [ -f old/deploy.sh ] \
  && ok "download $old" || { bad "download $old"; echo "=== exit 1"; exit 1; }
B=http://127.0.0.1:8080
export AZURE_VISION_KEY=fake AZURE_VISION_ENDPOINT=https://fake.test AUTH_MODE=none TLS_MODE=none TCP_PORT=8080 RTSP_URL=rtsp://10.0.0.1/s
health() { [ "$(curl -s -m 3 -o /dev/null -w '%{http_code}' "$B/healthz")" = 200 ]; }
field() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
budget=/var/lib/object_detector_web/budget.json

(cd old && bash deploy.sh install) > o1 2>&1 && ok "deploy $old" || { bad "deploy $old"; tail -8 o1 | cut -c1-170; echo "=== exit 1"; exit 1; }
within 60 health && ok "$old's /healthz answers" || bad "$old's /healthz doesn't answer"
st=$(curl -s -m 10 -H 'Content-Type: application/json' -d '{"type":"rtsp","name":"UI cam","url":"rtsp://10.0.0.2/ui"}' "$B/api/cameras" | field 'd.get("status")' 2>/dev/null)
[ "$st" = ok ] && ok "add a camera through the UI's API" || bad "couldn't add a camera: $st"
st=$(curl -s -m 10 -H 'Content-Type: application/json' -d '{"confidence":0.77}' "$B/api/config" | field 'd.get("status")' 2>/dev/null)
[ "$st" = ok ] && ok "change the confidence setting through the UI's API" || bad "couldn't change the setting: $st"
b1=$(sha256sum < "$budget" 2>/dev/null | cut -d' ' -f1)

(cd "$REPO" && bash deploy.sh install) > o2 2>&1 && ok "deploy the commit under test over $old" || { bad "deploy the commit under test over $old"; tail -10 o2 | cut -c1-170; }
for s in od-cameras od-web od-caddy; do systemctl is-active --quiet "$s" && ok "$s is active after the upgrade" || bad "$s isn't active after the upgrade"; done
within 60 health && ok "/healthz answers after the upgrade" || bad "/healthz doesn't answer after the upgrade"
names=$(curl -s -m 10 "$B/api/cameras" | field '" | ".join(sorted(c.get("name","") + "=" + c.get("url","") for c in d))' 2>/dev/null)
[[ "$names" == *"UI cam=rtsp://10.0.0.2/ui"* ]] && ok "the camera added in the UI survived" || bad "the UI camera is gone: $names"
[[ "$names" == *"=rtsp://10.0.0.1/s"* ]] && ok "the environment's camera is there" || bad "the environment's camera is gone: $names"
c=$(curl -s -m 10 "$B/api/config" | field 'd.get("confidence")' 2>/dev/null)
[ "$c" = 0.77 ] && ok "the setting changed in the UI survived" || bad "the confidence is $c, not 0.77"
if [ -n "$b1" ]; then
  [ "$(sha256sum < "$budget" 2>/dev/null | cut -d' ' -f1)" = "$b1" ] && ok "the persisted budget survived" || bad "the persisted budget changed or is gone"
fi
(cd "$REPO" && PURGE=true bash deploy.sh uninstall) > o3 2>&1 && ok "uninstall" || { bad "uninstall"; tail -6 o3 | cut -c1-170; }
systemctl is-active --quiet od-web && bad "od-web is still running" || ok "od-web is gone"
echo "=== exit $fail"; exit $fail
