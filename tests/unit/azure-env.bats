#!/usr/bin/env bats
# O12 (spec 21): azure.env is a systemd EnvironmentFile. Each test password is written as the key and as the endpoint,
# and read back the way systemd reads it (tests/systemd_env.py, checked against systemd 259 for these vectors), and must
# come back exactly.
load ../helpers
load ../vectors

setup() {
  setup_stubs
  load_script deploy.sh
  APP_DIR=$(mktemp -d)
  load_vectors
}

# reads_back <key> <endpoint>: what systemd reads from azure.env is exactly this key and endpoint
reads_back() {
  K=$1 E=$2 python3 -I -c 'import json,os,sys
d = json.load(sys.stdin)
assert d.get("AZURE_VISION_KEY") == os.environ["K"], "the key differs"
assert d.get("AZURE_VISION_ENDPOINT") == os.environ["E"], "the endpoint differs"' < <(python3 -I "$BATS_TEST_DIRNAME/../systemd_env.py" "$APP_DIR/azure.env")
}

@test "O12: every test password as the Azure key reaches the app exactly" {
  local n
  for n in "${VEC_NAMES[@]}"; do
    echo "vector: $n"
    AZURE_VISION_KEY=${VEC[$n]} AZURE_VISION_ENDPOINT=https://res.cognitiveservices.azure.com/
    write_azure_env >/dev/null
    reads_back "${VEC[$n]}" https://res.cognitiveservices.azure.com/
  done
}

@test "O12: a key ending in a backslash no longer swallows the endpoint, and a \\n stays two characters" {
  local k
  for k in 'Aa1\' 'Aa1\nx' '"Aa1"' "'Aa1'" '#Aa1' ' Aa1 '; do
    echo "key: [$k]"
    AZURE_VISION_KEY=$k AZURE_VISION_ENDPOINT='https://e.test/'
    write_azure_env >/dev/null
    reads_back "$k" 'https://e.test/'
  done
}

@test "O12: every test password as the endpoint reaches the app exactly, and the file is mode 0600 from the start" {
  local n
  for n in "${VEC_NAMES[@]}"; do
    AZURE_VISION_KEY=0123abcd AZURE_VISION_ENDPOINT=${VEC[$n]}
    write_azure_env >/dev/null
    reads_back 0123abcd "${VEC[$n]}"
  done
  # umask 077 while it's written: never readable by others, even before the chmod
  chmod() { :; }
  rm -f "$APP_DIR/azure.env"
  write_azure_env >/dev/null
  [ "$(stat -c %a "$APP_DIR/azure.env")" = 600 ]
}
