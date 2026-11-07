#!/usr/bin/env bats
# The Day-2 fixes (v1.1.0), function by function. APP_DIR points at a temp folder, so nothing touches a real host.
load ../helpers

setup() {
  setup_stubs
  load_script deploy.sh
  APP_DIR=$(mktemp -d); mkdir -p "$APP_DIR/state"
  CAMS="$APP_DIR/cameras.json" CFG="$APP_DIR/state/config.json"
  unset RTSP_URL CAMERAS_RESET
  for i in 1 2 3 4 5 6 7 8; do unset "CAMERA_${i}_URL" "CAMERA_${i}_NAME" "CAMERA_${i}_TYPE" "CAMERA_${i}_DEVICE"; done
  ENABLE_USB=false
}

ids() { python3 -c 'import json,sys; print(" ".join(c["id"]+"="+(c.get("url") or c.get("device") or "") for c in json.load(open(sys.argv[1]))["cameras"]))' "$CAMS"; }

# --- O4, O5 ---

@test "O4: a camera at rtsp://192.168.1.250 is kept" {
  RTSP_URL=rtsp://192.168.1.250:554/stream
  write_cameras_json >/dev/null
  [ "$(ids)" = "cam1=rtsp://192.168.1.250:554/stream" ]
}

@test "O5: a local camera needs only its device" {
  CAMERA_1_TYPE=local CAMERA_1_DEVICE=/dev/video0 CAMERA_1_NAME=Desk
  write_cameras_json >/dev/null
  [ "$(ids)" = "cam1=/dev/video0" ]
  python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))["cameras"][0]; assert c["type"]=="local" and c["name"]=="Desk"' "$CAMS"
}

@test "O5: a device with no type is local; a URL with no type is rtsp" {
  CAMERA_1_DEVICE=/dev/video2 CAMERA_2_URL=rtsp://10.0.0.9/s
  write_cameras_json >/dev/null
  python3 -c 'import json,sys; t=[c["type"] for c in json.load(open(sys.argv[1]))["cameras"]]; assert t==["local","rtsp"], t' "$CAMS"
}

@test "O5: an index with nothing usable is skipped with a warning, not silently" {
  CAMERA_1_TYPE=rtsp CAMERA_1_NAME=Nothing
  CAMERA_2_TYPE=rtsp CAMERA_2_DEVICE=/dev/video0
  run write_cameras_json
  [[ "$output" == *"CAMERA_1 is set, but has no CAMERA_1_URL or CAMERA_1_DEVICE"* ]]
  [[ "$output" == *"CAMERA_2_TYPE=rtsp needs CAMERA_2_URL"* ]]
  [ "$(ids)" = "" ]
}

# --- O2: merge ---

@test "O2: a re-run keeps cameras added in the UI, and marks its own" {
  RTSP_URL=rtsp://10.0.0.1/s
  write_cameras_json >/dev/null
  python3 - "$CAMS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["cameras"].append({"id": "cam2", "name": "UI", "type": "rtsp", "url": "rtsp://10.0.0.2/s", "enabled": True})
json.dump(d, open(sys.argv[1], "w"))
PY
  write_cameras_json >/dev/null
  [ "$(ids)" = "cam1=rtsp://10.0.0.1/s cam2=rtsp://10.0.0.2/s" ]
  python3 -c 'import json,sys; c={x["id"]:x for x in json.load(open(sys.argv[1]))["cameras"]}; assert c["cam1"]["source"]=="env" and "source" not in c["cam2"]' "$CAMS"
}

@test "O2: clearing RTSP_URL still removes its camera, and keeps the UI's" {
  printf '{"cameras":[{"id":"cam1","source":"env","url":"rtsp://10.0.0.1/s"},{"id":"cam2","url":"rtsp://10.0.0.2/s"}]}' > "$CAMS"
  write_cameras_json >/dev/null
  [ "$(ids)" = "cam2=rtsp://10.0.0.2/s" ]
}

@test "O2: on an id clash the environment wins" {
  printf '{"cameras":[{"id":"cam1","name":"UI one","url":"rtsp://10.0.0.7/s"}]}' > "$CAMS"
  RTSP_URL=rtsp://10.0.0.1/s
  write_cameras_json >/dev/null
  [ "$(ids)" = "cam1=rtsp://10.0.0.1/s" ]
}

@test "O2: a file from before 1.1.0 (no source field) keeps its other cameras, and its cam1 is replaced" {
  printf '{"cameras":[{"id":"cam1","name":"RTSP Camera","url":"rtsp://old/s"},{"id":"cam3","url":"rtsp://10.0.0.3/s"}]}' > "$CAMS"
  RTSP_URL=rtsp://new/s
  write_cameras_json >/dev/null
  [ "$(ids)" = "cam1=rtsp://new/s cam3=rtsp://10.0.0.3/s" ]
}

@test "O2: CAMERAS_RESET=true rebuilds from the environment only" {
  printf '{"cameras":[{"id":"cam2","url":"rtsp://10.0.0.2/s"}]}' > "$CAMS"
  RTSP_URL=rtsp://10.0.0.1/s CAMERAS_RESET=true
  write_cameras_json >/dev/null
  [ "$(ids)" = "cam1=rtsp://10.0.0.1/s" ]
}

@test "O2: a damaged cameras.json is replaced, not fatal" {
  echo "not json" > "$CAMS"
  RTSP_URL=rtsp://10.0.0.1/s
  write_cameras_json >/dev/null
  [ "$(ids)" = "cam1=rtsp://10.0.0.1/s" ]
}

# --- O7, O3: runtime settings ---

@test "O7: a first install writes every setting, from the environment or the defaults" {
  PASSED_SETTINGS=" AZURE_MONTHLY_BUDGET" AZURE_MONTHLY_BUDGET=100
  write_config_json >/dev/null
  python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); assert c["azure"]=={"api_version":"v4","monthly_budget":100,"budget_mode":"soft"}, c["azure"]; assert c["features"]["tags"] is True and c["confidence"]==0.5' "$CFG"
}

@test "O7: on a re-run, a passed setting replaces the kept value, and the run names it" {
  printf '{"azure":{"api_version":"v4","monthly_budget":4500,"budget_mode":"soft"},"confidence":0.7,"features":{"ocr":true}}' > "$CFG"
  PASSED_SETTINGS=" AZURE_MONTHLY_BUDGET AZURE_API_VERSION FEATURE_OCR" AZURE_MONTHLY_BUDGET=999 AZURE_API_VERSION=v3.2 FEATURE_OCR=false
  run write_config_json
  [[ "$output" == *"Applied from the environment: AZURE_MONTHLY_BUDGET=999, AZURE_API_VERSION=v3.2, FEATURE_OCR=false"* ]]
  python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); assert c["azure"]["monthly_budget"]==999 and c["azure"]["api_version"]=="v3.2" and c["features"]["ocr"] is False, c' "$CFG"
}

@test "O7: a setting not passed keeps what the file has, such as a change made in the UI" {
  printf '{"azure":{"api_version":"v4","monthly_budget":4500,"budget_mode":"hard"},"confidence":0.7,"keyword":{"terms":["dog"]}}' > "$CFG"
  PASSED_SETTINGS="" CONFIDENCE=0.5 AZURE_BUDGET_MODE=soft
  run write_config_json
  [[ "$output" != *"Applied"* ]]
  python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); assert c["confidence"]==0.7 and c["azure"]["budget_mode"]=="hard" and c["keyword"]["terms"]==["dog"], c' "$CFG"
}

@test "O7: booleans as Fabric renders them (True / False) are read correctly" {
  printf '{"features":{"ocr":false,"objects":true},"draw_boxes":true}' > "$CFG"
  PASSED_SETTINGS=" FEATURE_OCR FEATURE_OBJECTS DRAW_BOXES" FEATURE_OCR=True FEATURE_OBJECTS=False DRAW_BOXES=False
  write_config_json >/dev/null 2>&1
  python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); assert c["features"]=={"ocr":True,"objects":False} and c["draw_boxes"] is False, c' "$CFG"
}

@test "O1: a malformed passed setting fails before the app is touched, and leaves the file as it was" {
  printf '{"confidence":0.7}' > "$CFG"
  PASSED_SETTINGS=" CONFIDENCE" CONFIDENCE=abc
  run write_config_json
  [ "$status" -ne 0 ]
  [[ "$output" == *"A passed setting may be malformed"* ]]
  [ "$(cat "$CFG")" = '{"confidence":0.7}' ]
  [ ! -e "$CFG.new" ]
}

@test "O2: a cameras.json of the wrong shape is treated as empty" {
  echo '{"cameras": null}' > "$CAMS"
  RTSP_URL=rtsp://10.0.0.1/s
  write_cameras_json >/dev/null
  [ "$(ids)" = "cam1=rtsp://10.0.0.1/s" ]
}

@test "O7: settings passed at the top of the script are the ones recorded as passed" {
  run bash -c 'export AZURE_MONTHLY_BUDGET=12 CONFIDENCE=0.9; source "'"$BATS_TEST_DIRNAME"'/../../deploy.sh"; echo "[$PASSED_SETTINGS]"'
  [[ "$output" == *"CONFIDENCE"* && "$output" == *"AZURE_MONTHLY_BUDGET"* && "$output" != *"FEATURE_TAGS"* ]]
}

@test "O3: the banner reads state/config.json" {
  printf '{"azure":{"api_version":"v4","monthly_budget":100,"budget_mode":"soft"}}' > "$CFG"
  AZURE_MONTHLY_BUDGET=999
  [ "$(config_value azure monthly_budget)" = 100 ]
  [ "$(config_value azure api_version)" = v4 ]
}

# --- O6 and the input checks (O1 step 1) ---

@test "O6: TLS_MODE=auto refuses without a real FQDN, and goes ahead with one" {
  TLS_MODE=auto AUTH_MODE=none TCP_PORT=443 FQDN_GIVEN="" FQDN=od.host.lab
  run validate_inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"TLS_MODE=auto needs FQDN"* ]]
  FQDN_GIVEN=vision.example.com
  validate_inputs
  TLS_MODE=internal FQDN_GIVEN=""
  validate_inputs
}

@test "O1: a bad TLS_MODE, AUTH_MODE or TCP_PORT is refused before anything runs" {
  AUTH_MODE=none TCP_PORT=8080 FQDN_GIVEN=x
  TLS_MODE=bogus; run validate_inputs; [ "$status" -eq 1 ]
  TLS_MODE=none AUTH_MODE=digest; run validate_inputs; [ "$status" -eq 1 ]
  AUTH_MODE=basic TCP_PORT=99999; run validate_inputs; [ "$status" -eq 1 ]
  TCP_PORT=http; run validate_inputs; [ "$status" -eq 1 ]
  TCP_PORT=8080; validate_inputs
}

# --- O1: nothing stops the app before a step that can fail ---

order_setup() {
  AZURE_VISION_KEY=k AZURE_VISION_ENDPOINT=https://e TLS_MODE=none AUTH_MODE=none TCP_PORT=8080 FQDN_GIVEN=x
  require_root() { :; }; detect_distro() { :; }; is_offline() { return 1; }
  create_user_dirs() { echo create_user_dirs >> "$STUB_LOG"; }
  copy_app_files() { echo copy_app_files >> "$STUB_LOG"; }
  write_cameras_json() { echo write_cameras_json >> "$STUB_LOG"; }
  write_config_json() { echo write_config_json >> "$STUB_LOG"; }
  write_azure_env() { echo write_azure_env >> "$STUB_LOG"; }
  write_systemd() { echo write_systemd >> "$STUB_LOG"; }
  write_install_env() { echo write_install_env >> "$STUB_LOG"; }
  start_services() { echo start_services >> "$STUB_LOG"; }
  install_os_packages() { echo install_os_packages >> "$STUB_LOG"; }
  setup_venv() { echo setup_venv >> "$STUB_LOG"; }
  write_caddyfile() { echo write_caddyfile >> "$STUB_LOG"; }
  wait_healthy() { return 0; }
  config_value() { echo x; }
  stub systemctl
  stub mv
}

@test "O1: a failing Caddy download leaves the services running" {
  order_setup
  install_caddy() { echo install_caddy >> "$STUB_LOG"; die "Caddy download failed"; }
  run do_install
  [ "$status" -ne 0 ]
  ! called "systemctl stop"
}

@test "O1: a failing Caddyfile leaves the services running" {
  order_setup
  install_caddy() { :; }
  write_caddyfile() { die "generated Caddyfile failed validation"; }
  run do_install
  [ "$status" -ne 0 ]
  ! called "systemctl stop"
}

@test "O1: the services stop after every step that can fail, and before the swap" {
  order_setup
  install_caddy() { echo install_caddy >> "$STUB_LOG"; }
  run do_install
  [ "$status" -eq 0 ]
  stop=$(grep -n 'systemctl stop' "$STUB_LOG" | head -1 | cut -d: -f1)
  for step in install_os_packages install_caddy setup_venv write_caddyfile write_cameras_json write_config_json; do
    [ "$(grep -n "^$step\$" "$STUB_LOG" | cut -d: -f1)" -lt "$stop" ]
  done
  [ "$(grep -n '^copy_app_files$' "$STUB_LOG" | cut -d: -f1)" -gt "$stop" ]
}

@test "O1: an app that doesn't answer /healthz fails the install" {
  order_setup
  install_caddy() { :; }
  wait_healthy() { return 1; }
  run do_install
  [ "$status" -ne 0 ]
  [[ "$output" == *"didn't answer /healthz"* ]]
}
