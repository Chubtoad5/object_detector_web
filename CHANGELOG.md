# Changelog — object_detector_web

## v1.2.0 — 2026-11-12 — Any password works, and camera logins get their own settings

### Fixed
- **A camera whose password has `/`, `?` or `#` now connects** (spec 21, O8). The URL went to FFmpeg as typed, so the
  camera never connected and the log said only `failed to open capture`, and a `%` with two hex digits after it changed
  the password. The new `RTSP_USER` / `RTSP_PASSWORD`, `CAMERA_<N>_USER` / `CAMERA_<N>_PASSWORD`, and the **User** and
  **Password** fields of the Add Camera form take the login as typed. The installer and the app percent-encode them
  into the URL with the same code (`app/camera_url.py`), and FFmpeg decodes them under Basic and Digest auth alike.
- **An admin password over 72 bytes works** (O9). Caddy now hashes it with argon2id, reading it on stdin, so it's
  never on a command line, and the Caddyfile names `argon2id`. Before, the install stopped with Caddy's bcrypt error.
- **An admin user name Caddy can't carry is refused before anything changes** (O10). A space stopped the install, and
  `#admin` or `{$HOME}` gave a login that never worked. `ADMIN_USER` is now letters, digits and `. _ @ + -` (spec 21,
  Q2). A few names that did work, such as `admin!`, are refused too. A stored login whose name or hash this release
  can't use stops a re-run that doesn't pass `ADMIN_PASSWORD`, rather than going back to `changeme`; pass
  `ADMIN_USER` and `ADMIN_PASSWORD` to set it again.
- **A re-run without `ADMIN_PASSWORD` keeps the login** (O11). It reset the password to `changeme`. Now the stored
  login stays, an empty `ADMIN_PASSWORD` is refused, and only a first install with none gets `changeme`. A re-run with
  the same password keeps the same hash, so the Caddyfile doesn't change.
- **The Azure key and endpoint reach the app exactly** (O12). `azure.env` was written unquoted, so systemd dropped
  every `\` and the spaces at either end, and a key ending in `\` swallowed the endpoint. The values are now in double
  quotes with `\ " $` and `` ` `` escaped, and the file is mode `0600` from the moment it's written.
- **Camera passwords aren't shown** (O13). The Manage Cameras list and `GET /api/cameras` showed each camera's URL whole,
  password included. They now show `user:***@`, and the add and remove answers do too. The list is built as text, so a
  `<` or `&` in a camera's name or URL shows as typed and markup in it no longer runs; camera names in the grid, the
  events and the snapshots are escaped the same way. `cameras.json` is mode `0600`, from the installer and the app.

### Changed
- **New settings:** `RTSP_USER`, `RTSP_PASSWORD`, `CAMERA_<N>_USER` and `CAMERA_<N>_PASSWORD`. A URL with the login
  inside it, already encoded, works as before. The README shows how to encode one by hand.
- **Refused before anything is stopped or changed, each with a message that names the setting but never shows its
  value:**
  - an empty `ADMIN_PASSWORD`, one with a control character, or one over 128 characters;
  - an `ADMIN_USER` with anything but letters, digits and `. _ @ + -`;
  - a camera user with a `:`, a camera password without a user, a control character in either, a URL that has a login
    inside it and a separate user or password too, and, for an RTSP camera, a user and password over 127 bytes once
    percent-encoded. FFmpeg reads at most 127 and silently cuts the rest off.
- **A re-run without `ADMIN_USER` keeps the stored user,** where before it went back to `admin`.
- **The login is stored in `/etc/caddy/admin-login`** (mode `0600`): the user, the hash and a fingerprint of the
  password, so a re-run can tell whether the password changed. The first run of 1.2.0 over an older install keeps that
  install's bcrypt login when no `ADMIN_PASSWORD` is passed, and moves to argon2id when one is, which restarts Caddy
  once. `uninstall` removes the stored login.
- **The banner says which login is in use:** the password passed, the one kept, or the default `changeme`.
- `CADDY_VERSION` must be a Caddy release whose `hash-password` has argon2id. The default, 2.11.4, does.
- The app reports version 1.2.0 on `/healthz` (it said 1.1.0 through 1.1.1).

### Tests
- `tests/password-vectors.txt` and `tests/vectors.bash`: spec 21's test passwords, the same in every changed repo.
- `tests/unit/camera-login.bats`: each test password as a camera password and as a camera user, through the installer,
  read back the way FFmpeg reads the URL (`tests/ffmpeg_login.py`); the 127-byte limit; each refusal; `cameras.json`'s
  mode.
- `tests/unit/cameras-api.bats`: the same through the Add Camera route, with stand-ins for Flask and OpenCV
  (`tests/app_stub.py`); the app and the installer build the same URL; the masked API with the real file behind it; the
  list built as text.
- `tests/unit/admin-login.bats`: each test password reaches Caddy's `hash-password` on stdin, exactly; a re-run with no
  password, the same one and a new one; an empty one; a 1.1.1 Caddyfile; the user-name rule.
- `tests/unit/azure-env.bats`: each test password as the key and the endpoint, read back the way systemd reads an
  `EnvironmentFile` (`tests/systemd_env.py`, checked against systemd 259).
- `tests/secret-lint.py` and `tests/unit/secret-lint.bats`: spec 21's static check, which fails on an unquoted secret, or
  a secret given to `echo`, `eval`, `sed` or `--set`.
- `tests/integration/40-passwords.sh`: log in with the 128-character test password, keep it through re-runs, refusals
  that leave the app running, and a camera whose password is `Aa1@:/?#x`, given through `RTSP_PASSWORD` and through
  the form, connecting to a fake camera (`tests/integration/fake_camera.py`, Digest and Basic) that streams ffmpeg's
  test pattern.

## v1.1.1 — 2026-11-09 — save on Rocky and RHEL without ffmpeg

### Fixed
- **`save` works on a `dnf` host where no enabled repo has `ffmpeg`** (spec 15, F3), as on Rocky and RHEL, which have
  it in RPM Fusion. `save` asked for it anyway, and stopped. Now it leaves `ffmpeg` out and says so, as the online
  install already does. The camera feed doesn't need it, since OpenCV's wheel brings its own FFmpeg libraries. The bundle's
  `save-manifest.txt` lists what it holds, the offline install asks for that list, and the licence notice and written
  offer name `ffmpeg` only when the bundle holds it. A bundle from before v1.1.1 installs as before.

### Tests
- `tests/unit/save-packages.bats`: the list on `dnf` with and without `ffmpeg`, and on `apt`, the offline list from the
  manifest, and the licence text both ways.

## v1.1.0 — 2026-11-06 — Day-2 fixes

Every defect was reproduced on an Ubuntu 24.04 VM first, and each fix has a test that failed before it. Commands and
existing settings are unchanged.

### Fixed
- **A failing re-run took a working app down.** The services were stopped before packages, the Caddy download, the
  virtualenv and the Caddyfile, so a bad setting or a network failure left the app stopped. Inputs are now checked
  first, everything that can fail runs while the app keeps running, and the services stop only for the swap. After the
  start, the install waits up to 30 s for `/healthz` and exits 1 if the app doesn't answer.
- **A re-run deleted cameras added in the UI.** `cameras.json` is now merged, not rewritten (see the README's Cameras
  section). The new `CAMERAS_RESET=true` brings back the full rewrite.
- **A re-run ignored the runtime settings it was given,** because `state/config.json` is kept. A setting passed now
  replaces the kept value, and one not passed stays, so UI changes survive a re-run that doesn't mention them. The run
  names what it changed. **Note for `vision-tech-ops`:** it passes the API version, budget, budget mode, four features,
  confidence and boxes on every create and update, so its values now replace UI changes to those settings each time.
- **The banner showed the environment's Azure settings, not the ones in use.** It now reads `state/config.json`.
- **A camera URL starting `rtsp://192.168.1.250` was silently dropped,** a leftover guard for an old placeholder.
- **`CAMERA_<N>_TYPE=local` with only `_DEVICE` was skipped,** though the README documents it. A camera index with
  nothing usable is now skipped with a warning, not silently.
- **`TLS_MODE=auto` with no `FQDN` went ahead** with the `od.<hostname>` fallback, which no public CA will issue a
  certificate for. It now refuses, naming the fix.

### Added
- `CAMERAS_RESET`.

### Also in this release
- CI foundation: a source guard so tests can call functions, and `tests/unit` and `tests/contract`.

## v1.0.3

First entry in this file. `deploy.sh` was at `SCRIPT_VERSION=1.0.3` before this changelog existed: see the git history.
