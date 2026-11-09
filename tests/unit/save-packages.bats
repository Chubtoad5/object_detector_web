#!/usr/bin/env bats
# Spec 15, F3: on a dnf host with no repo that has ffmpeg, save leaves it out and says so, the offline install asks only
# for what the bundle holds, and the licence notice lists only that.
load ../helpers
setup() {
  setup_stubs
  load_script deploy.sh
  OFFLINE_DIR=$(mktemp -d)
  LICENSE_OFFER_CONTACT=me CADDY_VERSION=2.11.3
}
@test "dnf with no ffmpeg in any repo: save leaves it out, and says so" {
  PKG=dnf
  stub dnf 'exit 0'
  run save_pkg_list
  [ "$status" -eq 0 ]
  [[ "$output" == *"no enabled repo has ffmpeg"* ]]
  [[ "$(tail -1 <<< "$output")" == "python3 python3-pip mesa-libGL glib2" ]]
}
@test "dnf with ffmpeg in a repo, and apt: the full list" {
  PKG=dnf
  stub dnf 'echo ffmpeg-0:7.1-1.el10.x86_64'
  run save_pkg_list
  [ "$output" = "python3 python3-pip ffmpeg mesa-libGL glib2" ]
  PKG=apt
  run save_pkg_list
  [ "$output" = "python3-venv python3-pip ffmpeg libglib2.0-0t64 libgl1" ]
}
@test "the offline install asks for the bundle's list" {
  PKG=dnf
  printf 'os: rocky 10.1\nos_packages: python3 python3-pip mesa-libGL glib2\n' > "$OFFLINE_DIR/save-manifest.txt"
  [ "$(bundle_pkg_list)" = "python3 python3-pip mesa-libGL glib2" ]
}
@test "a bundle whose manifest has no list gets the distro's full list" {
  PKG=dnf
  printf 'os: rocky 10.1\n' > "$OFFLINE_DIR/save-manifest.txt"
  [ "$(bundle_pkg_list)" = "python3 python3-pip ffmpeg mesa-libGL glib2" ]
}
@test "licences: without ffmpeg, neither the notice nor the offer names it" {
  d=$(mktemp -d)
  generate_bundle_licenses "$d" "python3 python3-pip mesa-libGL glib2" >/dev/null
  ! grep -q ffmpeg "$d/LICENSES/THIRD_PARTY_NOTICES.txt"
  ! grep -q ffmpeg "$d/LICENSES/WRITTEN_OFFER.txt"
  grep -q "OS packages \[python3 python3-pip mesa-libGL glib2\]" "$d/LICENSES/THIRD_PARTY_NOTICES.txt"
  grep -q "including\$" "$d/LICENSES/WRITTEN_OFFER.txt"
  grep -q "^glib (LGPL)." "$d/LICENSES/WRITTEN_OFFER.txt"
}
@test "licences: with ffmpeg, both name it, as before" {
  d=$(mktemp -d)
  generate_bundle_licenses "$d" "python3-venv python3-pip ffmpeg libglib2.0-0t64 libgl1" >/dev/null
  grep -q "  ffmpeg .* GPL-2.0+" "$d/LICENSES/THIRD_PARTY_NOTICES.txt"
  grep -q "^ffmpeg (built under the GNU General Public License on Debian/Ubuntu) and glib (LGPL)." "$d/LICENSES/WRITTEN_OFFER.txt"
}
