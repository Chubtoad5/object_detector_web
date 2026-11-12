#!/usr/bin/env bats
# O8 and O13 (spec 21), deploy.sh's side: RTSP_USER / RTSP_PASSWORD and CAMERA_<N>_USER / _PASSWORD are percent-encoded
# into the camera's URL. Each test password goes in, and the URL is read back the way FFmpeg reads it
# (tests/ffmpeg_login.py): the camera must get exactly that user and password. APP_DIR is a temp folder.
load ../helpers
load ../vectors

setup() {
  setup_stubs
  load_script deploy.sh
  APP_DIR=$(mktemp -d); CAMS="$APP_DIR/cameras.json"
  unset RTSP_URL RTSP_USER RTSP_PASSWORD CAMERAS_RESET
  for i in 1 2 3 4 5 6 7 8; do
    unset "CAMERA_${i}_URL" "CAMERA_${i}_NAME" "CAMERA_${i}_TYPE" "CAMERA_${i}_DEVICE" "CAMERA_${i}_USER" "CAMERA_${i}_PASSWORD"
  done
  ENABLE_USB=false
  load_vectors
}

# url_of <camera id>: that camera's URL in cameras.json
url_of() { python3 -I -c 'import json,sys; print([c for c in json.load(open(sys.argv[1]))["cameras"] if c["id"]==sys.argv[2]][0]["url"])' "$CAMS" "$1"; }
# logs_in_as <url> <user> <password>: FFmpeg logs in to the camera with exactly this user and password
logs_in_as() { WANT_USER=$2 WANT_PASSWORD=$3 python3 -I "$BATS_TEST_DIRNAME/../ffmpeg_login.py" "$1"; }
# encoded_len <user> <password>: the bytes user:password takes percent-encoded
encoded_len() { U=$1 P=$2 python3 -I -c 'import os,sys; sys.path.insert(0, sys.argv[1]); import camera_url as c; print(len(c.encode(os.environ["U"]) + ":" + c.encode(os.environ["P"])))' "$BATS_TEST_DIRNAME/../../app"; }

@test "O8: every test password, given as CAMERA_1_PASSWORD, reaches the camera exactly" {
  local n url
  for n in "${VEC_NAMES[@]}"; do
    echo "vector: $n"
    CAMERA_1_URL=rtsp://10.0.0.9:554/stream CAMERA_1_USER=cam CAMERA_1_PASSWORD=${VEC[$n]}
    if [ "$(encoded_len cam "${VEC[$n]}")" -gt 127 ]; then
      # Too long for FFmpeg once encoded: refused, and the run says why (the next test)
      run write_cameras_json
      [ "$status" -ne 0 ]
      continue
    fi
    rm -f "$CAMS"
    write_cameras_json >/dev/null
    url=$(url_of cam1)
    [[ "$url" == rtsp://cam:*@10.0.0.9:554/stream ]]
    logs_in_as "$url" cam "${VEC[$n]}"
  done
}

@test "O8: every test password without a : works as the camera's user, and one with a : is refused" {
  local n
  for n in "${VEC_NAMES[@]}"; do
    echo "vector: $n"
    CAMERA_2_URL=rtsp://10.0.0.9/s CAMERA_2_USER=${VEC[$n]} CAMERA_2_PASSWORD='Aa1 pass'
    if [[ "${VEC[$n]}" == *:* || "$(encoded_len "${VEC[$n]}" 'Aa1 pass')" -gt 127 ]]; then
      run write_cameras_json
      [ "$status" -ne 0 ]
      continue
    fi
    rm -f "$CAMS"
    write_cameras_json >/dev/null
    logs_in_as "$(url_of cam2)" "${VEC[$n]}" 'Aa1 pass'
  done
}

@test "O8: RTSP_USER and RTSP_PASSWORD go into RTSP_URL, so a password with @ : / ? # connects" {
  RTSP_URL=rtsp://10.0.0.9:554/stream RTSP_USER=cam RTSP_PASSWORD=${VEC[url]}
  write_cameras_json >/dev/null
  [ "$(url_of cam1)" = 'rtsp://cam:Aa1%40%3A%2F%3F%23x@10.0.0.9:554/stream' ]
  logs_in_as "$(url_of cam1)" cam "${VEC[url]}"
}

@test "O8: a URL with the login already inside it is stored as given, as before" {
  RTSP_URL='rtsp://viewer:Aa1%40x@10.0.0.9/s?res=640x360&fps=10'
  write_cameras_json >/dev/null
  [ "$(url_of cam1)" = "$RTSP_URL" ]
  CAMERA_3_URL='rtsp://cam:pass@10.0.0.3/s'
  write_cameras_json >/dev/null
  [ "$(url_of cam3)" = 'rtsp://cam:pass@10.0.0.3/s' ]
}

@test "O8: FFmpeg's 127-byte limit: 127 bytes of user:password are taken, 128 are refused, naming both settings" {
  # cam: (4 bytes) + 123 unreserved characters = 127
  CAMERA_1_URL=rtsp://10.0.0.9/s CAMERA_1_USER=cam CAMERA_1_PASSWORD=$(printf 'A%.0s' $(seq 1 123))
  write_cameras_json >/dev/null
  logs_in_as "$(url_of cam1)" cam "$CAMERA_1_PASSWORD"
  # cam: (4) + 120 + @ (3 bytes once encoded) + 1 = 128
  CAMERA_1_PASSWORD="$(printf 'A%.0s' $(seq 1 120))@Z"
  run write_cameras_json
  [ "$status" -ne 0 ]
  [[ "$output" == *"CAMERA_1_USER and CAMERA_1_PASSWORD take 128 bytes once percent-encoded"* ]]
  [[ "$output" == *"at most 127"* ]]
  [[ "$output" != *"AAAA"* ]]
  # The long test password is refused the same way, and its value is never shown
  CAMERA_1_PASSWORD=${VEC[long]}
  run write_cameras_json
  [ "$status" -ne 0 ]
  [[ "$output" == *"CAMERA_1_PASSWORD"* ]]
  [[ "$output" != *"Aa1 !"* ]]
}

@test "O8: logins that can't work are refused, one message per setting, never showing the value" {
  RTSP_URL=rtsp://10.0.0.9/s RTSP_PASSWORD='Zq9secret'
  run write_cameras_json
  [ "$status" -ne 0 ]
  [[ "$output" == *"RTSP_PASSWORD needs RTSP_USER"* ]]
  RTSP_URL='rtsp://a:b@10.0.0.9/s' RTSP_USER=cam RTSP_PASSWORD='Zq9secret'
  run write_cameras_json
  [[ "$output" == *"RTSP_URL already has a user and password in it"* ]]
  RTSP_URL=rtsp://10.0.0.9/s RTSP_USER=cam RTSP_PASSWORD=$'Zq9\tsecret'
  run write_cameras_json
  [[ "$output" == *"RTSP_PASSWORD can't contain a control character"* ]]
  RTSP_USER='ca:m' RTSP_PASSWORD='Zq9secret'
  run write_cameras_json
  [[ "$output" == *"RTSP_USER can't contain ':'"* ]]
  [[ "$output" != *"Zq9"* ]]
  [ ! -e "$CAMS" ] && [ ! -e "$CAMS.new" ]
}

@test "O8: a bad camera login is refused by validate_inputs, before anything runs" {
  TLS_MODE=none AUTH_MODE=none TCP_PORT=8080 FQDN_GIVEN=x
  CAMERA_4_URL=rtsp://10.0.0.4/s CAMERA_4_PASSWORD='Zq9secret'
  run validate_inputs
  [ "$status" -ne 0 ]
  [[ "$output" == *"CAMERA_4_PASSWORD needs CAMERA_4_USER"* ]]
  [[ "$output" == *"Nothing was changed"* ]]
  CAMERA_4_USER=cam
  validate_inputs
}

@test "O8: a user with no password is a login with an empty password, and a lone RTSP_USER is named, not lost" {
  RTSP_URL=rtsp://10.0.0.9/s RTSP_USER=cam
  write_cameras_json >/dev/null
  logs_in_as "$(url_of cam1)" cam ''
  unset RTSP_URL
  run write_cameras_json
  [[ "$output" == *"RTSP_USER or RTSP_PASSWORD is set, but RTSP_URL isn't"* ]]
}

@test "O13: cameras.json is mode 0600, and a re-run makes an older 0644 one 0600" {
  RTSP_URL=rtsp://10.0.0.9/s RTSP_USER=cam RTSP_PASSWORD='Aa1pass'
  write_cameras_json >/dev/null
  [ "$(stat -c %a "$CAMS")" = 600 ]
  chmod 644 "$CAMS"
  write_cameras_json >/dev/null
  [ "$(stat -c %a "$CAMS")" = 600 ]
}
