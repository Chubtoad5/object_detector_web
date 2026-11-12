#!/usr/bin/env bats
# O9-O11 (spec 21): the admin login. do_install runs for real through validate_inputs, write_caddyfile and the swap, with
# every other step stubbed, Caddy's directory in a temp folder, and a stub Caddy that records what hash-password gets
# on stdin and in its arguments. Its "hash" is a digest of what it read, so a test can tell which password was hashed.
load ../helpers
load ../vectors

setup() {
  setup_stubs
  load_script deploy.sh
  APP_DIR=$(mktemp -d); CADDY_DIR=$(mktemp -d)/caddy; CADDY_BIN=$STUB_DIR/caddy
  stub caddy 'if [ "$1" = hash-password ]; then
    cat > "${STUB_LOG%/*}/hash.stdin"; echo "$*" > "${STUB_LOG%/*}/hash.args"
    printf "\$argon2id\$v=19\$m=47104,t=1,p=1\$c2FsdA\$%s\n" "$(sha256sum < "${STUB_LOG%/*}/hash.stdin" | cut -c1-43)"
  fi'
  AZURE_VISION_KEY=k AZURE_VISION_ENDPOINT=https://e TLS_MODE=none AUTH_MODE=basic TCP_PORT=8080 FQDN_GIVEN=x MGMT_IP=127.0.0.1
  require_root() { :; }; detect_distro() { :; }; is_offline() { return 1; }
  for f in install_os_packages install_caddy create_user_dirs setup_venv write_cameras_json write_config_json \
           copy_app_files write_azure_env write_systemd write_install_env start_services; do
    eval "$f() { echo $f >> \"\$STUB_LOG\"; }"
  done
  wait_healthy() { return 0; }
  config_value() { echo x; }
  stub systemctl
  ADMIN_USER_GIVEN="" ADMIN_USER=admin
  load_vectors
}

# run_install [ADMIN_PASSWORD=...] [ADMIN_USER=...]: one deploy.sh run, which gets only the settings given
run_install() {
  unset ADMIN_PASSWORD; ADMIN_PASSWORD_SET="" ADMIN_USER_GIVEN="" ADMIN_USER=admin
  : > "$STUB_LOG"
  local kv
  for kv in "$@"; do
    case "$kv" in
      ADMIN_PASSWORD=*) ADMIN_PASSWORD=${kv#*=}; ADMIN_PASSWORD_SET=set ;;
      ADMIN_USER=*) ADMIN_USER=${kv#*=}; ADMIN_USER_GIVEN=${kv#*=} ;;
    esac
  done
  rm -f "$STUB_DIR/hash.stdin"
  run do_install
}
# logs_in_with <password>: the Caddyfile's hash was made from exactly this password
logs_in_with() {
  local want
  want=$(printf '%s\n' "$1" | sha256sum | cut -c1-43)
  grep -qF " \$argon2id\$v=19\$m=47104,t=1,p=1\$c2FsdA\$$want" "$CADDY_DIR/Caddyfile"
}
hashed() { [ -e "$STUB_DIR/hash.stdin" ]; }

@test "O9: every test password reaches Caddy's hash-password on stdin, exactly, and never in its arguments" {
  local n
  for n in "${VEC_NAMES[@]}"; do
    echo "vector: $n"
    rm -f "$CADDY_DIR"/*
    run_install ADMIN_PASSWORD="${VEC[$n]}"
    [ "$status" -eq 0 ]
    # Caddy reads up to the newline and drops it: what it hashes is the password, byte for byte
    [ "$(cat "$STUB_DIR/hash.stdin")" = "${VEC[$n]}" ]
    [ "$(wc -c < "$STUB_DIR/hash.stdin")" -eq $(( $(printf '%s' "${VEC[$n]}" | wc -c) + 1 )) ]
    [ "$(cat "$STUB_DIR/hash.args")" = "hash-password --algorithm argon2id" ]
    logs_in_with "${VEC[$n]}"
  done
}

@test "O9: the Caddyfile names argon2id, so a password over 72 bytes works" {
  run_install ADMIN_PASSWORD="${VEC[long]}"
  [ "$status" -eq 0 ]
  grep -q '^    basic_auth argon2id {$' "$CADDY_DIR/Caddyfile"
  grep -q '^      admin \$argon2id\$' "$CADDY_DIR/Caddyfile"
  [ "$(stat -c %a "$CADDY_DIR/admin-login")" = 600 ]
  [ ! -e "$CADDY_DIR/admin-login.new" ] && [ ! -e "$CADDY_DIR/Caddyfile.new" ]
}

@test "O11: a re-run without ADMIN_PASSWORD keeps the login, and doesn't hash anything" {
  run_install ADMIN_PASSWORD="${VEC[long]}"
  cp "$CADDY_DIR/Caddyfile" "$BATS_TEST_TMPDIR/before"
  run_install
  [ "$status" -eq 0 ]
  ! hashed
  logs_in_with "${VEC[long]}"
  cmp "$CADDY_DIR/Caddyfile" "$BATS_TEST_TMPDIR/before"
  [[ "$output" == *"Login: admin / (the password set before"* ]]
}

@test "O11: an empty ADMIN_PASSWORD is refused before anything runs, and the login stays" {
  run_install ADMIN_PASSWORD='Aa1pass'
  run_install ADMIN_PASSWORD=
  [ "$status" -ne 0 ]
  [[ "$output" == *"ADMIN_PASSWORD is set but empty"* ]]
  ! called install_os_packages
  ! called "systemctl stop"
  logs_in_with 'Aa1pass'
}

@test "O11: a first install with no ADMIN_PASSWORD still gets changeme, and says so" {
  run_install
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_DIR/hash.stdin")" = changeme ]
  logs_in_with changeme
  [[ "$output" == *"Login: admin / changeme (the default"* ]]
}

@test "Q5: the same password again keeps the stored hash, so the Caddyfile doesn't change; a new one is hashed" {
  run_install ADMIN_PASSWORD="${VEC[full]}"
  cp "$CADDY_DIR/Caddyfile" "$BATS_TEST_TMPDIR/before"
  run_install ADMIN_PASSWORD="${VEC[full]}"
  [ "$status" -eq 0 ]
  ! hashed
  cmp "$CADDY_DIR/Caddyfile" "$BATS_TEST_TMPDIR/before"
  run_install ADMIN_PASSWORD="${VEC[dollar]}"
  hashed
  logs_in_with "${VEC[dollar]}"
}

@test "O11: an upgrade from 1.1.1 without ADMIN_PASSWORD keeps its user and bcrypt login; with one it moves to argon2id" {
  mkdir -p "$CADDY_DIR"
  printf ':8080 {\n  handle {\n    basic_auth {\n      bob $2a$14$abcdefghijklmnopqrstuuOldHashOldHashOldHashOldHashOld\n    }\n    reverse_proxy unix//x/web.sock\n  }\n}\n' > "$CADDY_DIR/Caddyfile"
  run_install
  [ "$status" -eq 0 ]
  ! hashed
  grep -q '^    basic_auth bcrypt {$' "$CADDY_DIR/Caddyfile"
  grep -qF '      bob $2a$14$abcdefghijklmnopqrstuuOldHashOldHashOldHashOldHashOld' "$CADDY_DIR/Caddyfile"
  run_install ADMIN_PASSWORD='Aa1 new pass'
  grep -q '^    basic_auth argon2id {$' "$CADDY_DIR/Caddyfile"
  logs_in_with 'Aa1 new pass'
  grep -q '^      bob ' "$CADDY_DIR/Caddyfile"
}

@test "O11: ADMIN_USER passed replaces the stored user; not passed, the stored user stays" {
  run_install ADMIN_PASSWORD='Aa1pass' ADMIN_USER=ops@site
  grep -q '^      ops@site ' "$CADDY_DIR/Caddyfile"
  run_install
  grep -q '^      ops@site ' "$CADDY_DIR/Caddyfile"
  run_install ADMIN_USER=viewer
  grep -q '^      viewer ' "$CADDY_DIR/Caddyfile"
  logs_in_with 'Aa1pass'
}

@test "O10: admin user names are letters, digits and . _ @ + -, checked before anything runs" {
  local u
  for u in admin Admin_2 ops.team@example.com a+b-c @admin -admin; do
    echo "allowed: $u"
    valid_admin_user "$u"
  done
  for u in 'ad min' '#admin' '{$HOME}' 'ad:min' 'ad"min' "ad'min" 'ad\min' 'adé' $'ad\tmin' ''; do
    echo "refused: [$u]"
    ! valid_admin_user "$u"
  done
  run_install ADMIN_PASSWORD='Aa1pass' ADMIN_USER='ad min'
  [ "$status" -ne 0 ]
  [[ "$output" == *"ADMIN_USER can only have letters, digits and . _ @ + -"* ]]
  ! called install_os_packages
  [ ! -e "$CADDY_DIR/Caddyfile" ]
}

@test "The promise: a password with a control character, or over 128 characters, is refused before anything runs" {
  run_install ADMIN_PASSWORD=$'Aa1\tpass'
  [ "$status" -ne 0 ]
  [[ "$output" == *"ADMIN_PASSWORD can't contain a control character"* ]]
  run_install ADMIN_PASSWORD="${VEC[long]}x"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ADMIN_PASSWORD is longer than 128 characters"* ]]
  [[ "$output" != *"Aa1 !"* ]]
  ! called install_os_packages
}

@test "AUTH_MODE=none needs no password, and keeps the stored login for a later switch back" {
  run_install ADMIN_PASSWORD='Aa1pass'
  AUTH_MODE=none
  run_install ADMIN_PASSWORD=
  [ "$status" -eq 0 ]
  ! grep -q basic_auth "$CADDY_DIR/Caddyfile"
  AUTH_MODE=basic
  run_install
  logs_in_with 'Aa1pass'
}
