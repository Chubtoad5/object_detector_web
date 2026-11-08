#!/bin/bash
# A1, on a host with no route out: install from the bundle the build role made, beside this repo's deploy.sh, as save
# says to. Fake Azure values, as the integration test uses: the check is that the app runs and serves.
set -uo pipefail
REPO=$PWD
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
# within <seconds> <command...>: true once the command is, checking every 3 seconds
within() { local t=$1 i; shift; for ((i = 0; i < t; i += 3)); do "$@" && return 0; sleep 3; done; "$@"; }
W=$(mktemp -d -p /var/tmp); cd "$W" || exit 1
cd "$REPO" || exit 1
cp "$CI_HANDOFF/od-save.tar.gz" . && ok "put the bundle beside deploy.sh" || { bad "put the bundle beside deploy.sh"; echo "=== exit 1"; exit 1; }
export AZURE_VISION_KEY=fake AZURE_VISION_ENDPOINT=https://fake.test AUTH_MODE=none TLS_MODE=none TCP_PORT=8080 RTSP_URL=rtsp://10.0.0.1/s
./deploy.sh install > "$W/o" 2>&1 && ok "install with no route out" || { bad "install with no route out"; tail -8 "$W/o" | cut -c1-170; echo "  (the checks after it would only fail too)"; echo "=== exit 1"; exit 1; }
grep -qi "offline" "$W/o" && ok "it installs from the bundle" || bad "it didn't say it used the bundle"
for s in od-cameras od-web od-caddy; do systemctl is-active --quiet "$s" && ok "$s is active" || bad "$s isn't active"; done
health() { [ "$(curl -s -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/healthz)" = 200 ]; }
within 60 health && ok "/healthz answers" || bad "/healthz doesn't answer"
PURGE=true ./deploy.sh uninstall > "$W/o" 2>&1 && ok "uninstall" || { bad "uninstall"; tail -6 "$W/o" | cut -c1-170; }
systemctl is-active --quiet od-web && bad "od-web is still running" || ok "od-web is gone"
rm -f od-save.tar.gz
echo "=== exit $fail"; exit $fail
