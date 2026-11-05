#!/usr/bin/env bats
SCRIPT="$BATS_TEST_DIRNAME/../../deploy.sh"
@test "version needs no root" {
  run su -s /bin/bash nobody -c "bash '$SCRIPT' version"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}
@test "help lists the commands" {
  run "$SCRIPT" help
  [ "$status" -eq 0 ]
  for c in install save uninstall status; do [[ "$output" == *"$c"* ]]; done
}
@test "install needs the Azure settings, before it touches anything" {
  run "$SCRIPT" install
  [ "$status" -ne 0 ]
}
@test "an unknown command is an error" {
  run "$SCRIPT" nope
  [ "$status" -ne 0 ]
}
