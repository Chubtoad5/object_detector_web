#!/usr/bin/env bats
# Spec 28: save fetches install-packages at a pinned release, not its main.
load ../helpers
setup() {
  setup_stubs
  unset INSTALL_PACKAGES_REF INSTALL_PKGS_URL INSTALL_PACKAGES_URL
}
@test "the default is install-packages v1.1.3, never main" {
  load_script deploy.sh
  [ "$INSTALL_PACKAGES_REF" = v1.1.3 ]
  [ "$INSTALL_PKGS_URL" = "https://raw.githubusercontent.com/Chubtoad5/install-packages/v1.1.3/install_packages.sh" ]
  ! grep -q 'install-packages/main/' "$BATS_TEST_DIRNAME/../../deploy.sh" || false
}
@test "INSTALL_PACKAGES_REF picks the release, and INSTALL_PKGS_URL wins over it" {
  export INSTALL_PACKAGES_REF=v9.9.9
  load_script deploy.sh
  [ "$INSTALL_PKGS_URL" = "https://raw.githubusercontent.com/Chubtoad5/install-packages/v9.9.9/install_packages.sh" ]
  export INSTALL_PKGS_URL=https://example.test/ip.sh
  load_script deploy.sh
  [ "$INSTALL_PKGS_URL" = https://example.test/ip.sh ]
}
@test "a ref that isn't a tag, branch or commit name is refused" {
  load_script deploy.sh
  for bad in '../x' 'v1;rm' 'a b' '-x' '?q=1'; do
    INSTALL_PACKAGES_REF=$bad run check_install_packages_ref
    [ "$status" -ne 0 ] || { echo "accepted: $bad"; false; }
  done
  for good in v1.1.3 feature/x 0123abc; do
    INSTALL_PACKAGES_REF=$good run check_install_packages_ref
    [ "$status" -eq 0 ] || { echo "refused: $good"; false; }
  done
}
@test "save checks the ref before it fetches" {
  grep -B1 'curl -fsSL "$INSTALL_PKGS_URL"' "$BATS_TEST_DIRNAME/../../deploy.sh" | grep -q 'check_install_packages_ref'
}
@test "INSTALL_PACKAGES_URL, the suite's other name, works too, and a given URL skips the ref check" {
  export INSTALL_PACKAGES_URL=https://example.test/ip2.sh INSTALL_PACKAGES_REF='a b'
  load_script deploy.sh
  [ "$INSTALL_PKGS_URL" = https://example.test/ip2.sh ]
  [ "$INSTALL_PKGS_URL_GIVEN" = 1 ]
  unset INSTALL_PACKAGES_URL INSTALL_PACKAGES_REF INSTALL_PKGS_URL
  load_script deploy.sh
  [ "$INSTALL_PKGS_URL_GIVEN" = 0 ]
}
