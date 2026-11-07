# Changelog — object_detector_web

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
