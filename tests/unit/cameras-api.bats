#!/usr/bin/env bats
# O8 and O13 (spec 21), the app's side: the Add Camera form's user and password are percent-encoded into the URL as
# deploy.sh does it, the API shows each camera password as ***, and cameras.json keeps the real one at mode 0600.
# app/app.py runs with stand-ins for Flask, OpenCV and Azure (tests/app_stub.py); camera_url is the real one.
load ../helpers
load ../vectors

setup() {
  APP_DIR=$(mktemp -d); mkdir -p "$APP_DIR/state"
  load_vectors
}

# api <python>: runs the Python with app (the loaded app), call, ffmpeg_login and APP_DIR ready
api() {
  python3 -I - "$BATS_TEST_DIRNAME/.." "$APP_DIR" "$1" <<'PY'
import json, os, sys
sys.path.insert(0, sys.argv[1])
import app_stub, ffmpeg_login
APP_DIR = sys.argv[2]
app = app_stub.load(APP_DIR)
call = lambda *a: app_stub.call(app, *a)
stored = lambda: json.load(open(os.path.join(APP_DIR, "cameras.json")))["cameras"]
exec(sys.argv[3])
PY
}

@test "O8: every test password typed in the Add Camera form reaches the camera exactly, or is refused when FFmpeg can't take it" {
  local n
  for n in "${VEC_NAMES[@]}"; do
    echo "vector: $n"
    PW=${VEC[$n]} api '
pw = os.environ["PW"]
body, code = call("POST", app.api_cameras, {"type": "rtsp", "name": "Gate", "url": "rtsp://10.0.0.9:554/s", "user": "cam", "password": pw})
from urllib.parse import quote
if len("cam:" + quote(pw, safe="")) > 127:
    assert code == 400 and "127" in body["message"] and pw not in body["message"], body
else:
    assert code == 200, body
    url = stored()[-1]["url"]
    problem = ffmpeg_login.check(url, "cam", pw)
    assert not problem, problem
'
  done
}

@test "O8: the app and deploy.sh build the same URL for every test password" {
  local n deploy_url
  load_script deploy.sh
  for n in "${VEC_NAMES[@]}"; do
    [ "$n" = long ] && continue
    echo "vector: $n"
    rm -f "$APP_DIR/cameras.json"
    CAMERAS_RESET=true ENABLE_USB=false CAMERA_1_URL=rtsp://10.0.0.9/s CAMERA_1_USER=cam CAMERA_1_PASSWORD=${VEC[$n]}
    write_cameras_json >/dev/null
    deploy_url=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["cameras"][0]["url"])' "$APP_DIR/cameras.json")
    rm -f "$APP_DIR/cameras.json"
    PW=${VEC[$n]} WANT=$deploy_url api '
body, code = call("POST", app.api_cameras, {"type": "rtsp", "url": "rtsp://10.0.0.9/s", "user": "cam", "password": os.environ["PW"]})
assert stored()[0]["url"] == os.environ["WANT"], "the app and deploy.sh differ"
'
  done
}

@test "O13: GET /api/cameras shows each password as ***, and cameras.json keeps the real one" {
  printf '%s' '{"cameras":[{"id":"cam1","name":"A","type":"rtsp","url":"rtsp://cam:Aa1%40%3Ax@10.0.0.1/s"},{"id":"cam2","name":"B","type":"rtsp","url":"rtsp://10.0.0.2/s"},{"id":"cam3","name":"C","type":"rtsp","url":"rtsp://viewer@10.0.0.3/s"},{"id":"usb0","name":"U","type":"local","device":"/dev/video0"}]}' > "$APP_DIR/cameras.json"
  api '
body, code = call("GET", app.api_cameras)
urls = [c.get("url") for c in body]
assert urls == ["rtsp://cam:***@10.0.0.1/s", "rtsp://10.0.0.2/s", "rtsp://viewer@10.0.0.3/s", None], urls
assert stored()[0]["url"] == "rtsp://cam:Aa1%40%3Ax@10.0.0.1/s"
'
}

@test "O13: adding and removing a camera answers with masked URLs, never writes the mask back, and leaves cameras.json 0600" {
  printf '%s' '{"cameras":[{"id":"cam1","name":"A","type":"rtsp","url":"rtsp://cam:Aa1%40%3Ax@10.0.0.1/s"}]}' > "$APP_DIR/cameras.json"
  chmod 644 "$APP_DIR/cameras.json"
  api '
body, code = call("POST", app.api_cameras, {"type": "rtsp", "name": "B", "url": "rtsp://10.0.0.2/s", "user": "u", "password": "Aa1 #x"})
assert code == 200, body
assert body["camera"]["url"] == "rtsp://u:***@10.0.0.2/s", body["camera"]
assert [c["url"] for c in body["cameras"]] == ["rtsp://cam:***@10.0.0.1/s", "rtsp://u:***@10.0.0.2/s"], body
assert [c["url"] for c in stored()] == ["rtsp://cam:Aa1%40%3Ax@10.0.0.1/s", "rtsp://u:Aa1%20%23x@10.0.0.2/s"], stored()
assert oct(os.stat(os.path.join(APP_DIR, "cameras.json")).st_mode & 0o777) == "0o600"
body, code = call("DELETE", app.api_camera_delete, None, "cam2")
assert [c["url"] for c in body["cameras"]] == ["rtsp://cam:***@10.0.0.1/s"], body
assert [c["url"] for c in stored()] == ["rtsp://cam:Aa1%40%3Ax@10.0.0.1/s"], stored()
assert oct(os.stat(os.path.join(APP_DIR, "cameras.json")).st_mode & 0o777) == "0o600"
'
}

@test "O8: the form refuses a login that can't work, with a message that names the field and never the value" {
  api '
cases = [({"user": "", "password": "Zq9secret"}, "Password needs User"),
         ({"user": "ca:m", "password": "Zq9secret"}, "User can'"'"'t contain"),
         ({"user": "cam", "password": "Zq9\nsecret"}, "Password can'"'"'t contain a control character")]
for extra, want in cases:
    body, code = call("POST", app.api_cameras, dict({"type": "rtsp", "url": "rtsp://10.0.0.2/s"}, **extra))
    assert code == 400 and want in body["message"] and "Zq9" not in body["message"], body
body, code = call("POST", app.api_cameras, {"type": "rtsp", "url": "rtsp://a:b@10.0.0.2/s", "user": "cam", "password": "Zq9secret"})
assert code == 400 and "already has a user and password" in body["message"], body
assert not os.path.exists(os.path.join(APP_DIR, "cameras.json"))
'
}

@test "O8: a URL with the login inside it, and a camera with no login, are stored as typed" {
  api '
for url in ["rtsp://viewer:Aa1%40x@10.0.0.5/s?a=1&b=2", "rtsp://10.0.0.6:8554/live", "http://10.0.0.7/mjpg"]:
    body, code = call("POST", app.api_cameras, {"type": "rtsp", "url": url})
    assert code == 200 and stored()[-1]["url"] == url, (url, body)
'
}

@test "O13: the mask hides a password typed into the URL with a raw / or @ in it" {
  api '
import camera_url
m = camera_url.mask_url
assert m("rtsp://cam:Aa1/x@10.0.0.1/s") == "rtsp://cam:***@10.0.0.1/s"
assert m("rtsp://cam:Aa1@x@10.0.0.1/s") == "rtsp://cam:***@10.0.0.1/s"
assert m("rtsp://cam:Aa1%40x@10.0.0.1:554/s?x=1") == "rtsp://cam:***@10.0.0.1:554/s?x=1"
assert m("rtsp://10.0.0.1/s?mail=a@b") == "rtsp://10.0.0.1/s?mail=a@b"
'
}

@test "O13: the Manage Cameras list is built with textContent, and the form sends a user and a password" {
  local page=$BATS_TEST_DIRNAME/../../app/templates/index.html list
  list=$(sed -n '/^async function loadCamsList/,/^}/p' "$page")
  [ -n "$list" ]
  [[ "$list" == *"textContent=c.name"* ]]
  [[ "$list" != *'innerHTML=`'* ]]
  grep -q 'id="newCamUser"' "$page"
  grep -q 'type="password" class="half" id="newCamPass"' "$page"
  sed -n '/^async function addCam/,/^}/p' "$page" | grep -q "body.password=document.getElementById('newCamPass').value;"
  # Camera names in the grid, the events and the snapshots go through esc()
  ! grep -nE '\$\{(c\.name|e\.cam_name|m\.cam_name)' "$page"
}
