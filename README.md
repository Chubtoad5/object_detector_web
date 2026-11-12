# Object Detector Web

A containerless, single-node web app that shows **multiple live camera feeds at once**
(USB or RTSP) and runs on-demand or interval **Azure AI Vision** analysis on them —
object detection with bounding boxes, captions, tags, people, OCR, and more. It ships
as one `deploy.sh` that installs everything (Caddy + a Python/gunicorn app + systemd),
with optional self-signed TLS and basic auth, and a full air-gap install path.

> Built to stay **free**: it targets the Azure Computer Vision **F0 free tier** and
> includes a per-feature transaction meter + a monthly budget guard so analysis never
> runs up a bill.

---

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Commands](#commands)
- [Configuration (environment variables)](#configuration-environment-variables)
- [Cameras](#cameras)
- [Azure AI Vision & the free tier](#azure-ai-vision--the-free-tier)
- [Security](#security)
- [Air-gapped install](#air-gapped-install)
- [How it works](#how-it-works)
- [Uninstall](#uninstall)
- [Upstream / Credits](#upstream--credits)
- [License](#license)

---

## Features

- **Multi-camera grid** — every configured camera streams simultaneously (no switch button).
- **Add/remove cameras from the UI** — RTSP/network or USB/local, with **USB auto-discovery**.
- **Azure AI Vision** (4.0 SDK, with optional legacy 3.2 fallback): objects + bounding boxes,
  caption, tags, people, dense captions, OCR/Read; legacy-only Brands/Color. Boxes are a
  point-in-time snapshot, so they **fade out after ~5 seconds** (and are replaced as soon as the
  next manual or auto analysis returns) rather than lingering over the moving feed.
- **Toggle everything** — every feature is switchable in the UI *and* via deploy-time env defaults.
- **Keyword/tag watch** — flash + sound + desktop notification + event log when a term is seen.
- **Interval auto-analyze** with a persistent **free-tier budget guard** (auto-pause, 429 backoff).
- **Snapshots** (manual or detection-triggered) with a thumbnail gallery, metadata, and download.
- **Click-to-expand** any camera into a focus modal.
- **Optional self-signed TLS + basic auth** via Caddy. **Air-gap** install supported.

## Requirements

- A supported Linux distro: **Ubuntu/Debian**, **RHEL family** (RHEL/Rocky/Alma/Fedora), or **SLES**.
  *(v1.0 is smoke-tested on Ubuntu 24.04; the RHEL/SLES package paths are implemented but not yet validated.)*
- Root (`sudo`).
- An **Azure Computer Vision / Azure AI Vision** resource (use the **F0 free tier** for $0). Key + endpoint.
- At least one camera reachable from the host: an **RTSP** URL, and/or a **USB** camera at `/dev/video0`.

## Quick start

```bash
git clone https://github.com/Chubtoad5/object_detector_web.git
cd object_detector_web
chmod +x deploy.sh
sudo AZURE_VISION_KEY="<your-key>" \
     AZURE_VISION_ENDPOINT="https://<your-resource>.cognitiveservices.azure.com/" \
     RTSP_URL="rtsp://192.168.1.50:554/stream" \
     RTSP_USER="viewer" RTSP_PASSWORD='<camera password>' \
     ADMIN_PASSWORD='<admin password>' \
     ./deploy.sh
```

Then open `https://<server-ip>/` and log in as `admin` / `<ADMIN_PASSWORD>`.
Put passwords in single quotes, so the shell passes them as typed (write a `'` in one as `'\''`).
(Default TLS is self-signed — accept the one-time browser warning. Set `TLS_MODE=none` for plain HTTP on port 80.)

Add more cameras live from the **🎥 Cameras** button, tune inference in **⚙ Settings**, and view captures in **🖼 Snapshots**.

## Commands

```bash
sudo ./deploy.sh [command]
```

| Command | Description |
|---------|-------------|
| `install` (default) | Deploy/refresh. Auto-detects an air-gap bundle (`od-save.tar.gz`) and installs offline. |
| `save` | Build an air-gap bundle (`od-save.tar.gz`): OS packages, Python wheels, Caddy binary. |
| `uninstall` | Stop + remove (set `PURGE=true` to also delete state/snapshots). |
| `status` | Show service + health status. |
| `version` / `help` | Info. |

## Configuration (environment variables)

All are runtime-overridable: `sudo VAR=value ./deploy.sh`.

| Variable | Default | Description |
|----------|---------|-------------|
| `AZURE_VISION_KEY` | – (required) | Azure Computer Vision key. |
| `AZURE_VISION_ENDPOINT` | – (required) | `https://<resource>.cognitiveservices.azure.com/`. |
| `AZURE_API_VERSION` | `v4` | `v4` (modern) or `v3.2` (legacy; enables Brands/Color). |
| `AZURE_MONTHLY_BUDGET` | `4500` | Monthly transaction cap the guard enforces (F0 free cap is 5000). |
| `AZURE_BUDGET_MODE` | `soft` | `soft` (warn) or `hard` (block at the cap). |
| `RTSP_URL` | – | Convenience single RTSP camera. |
| `RTSP_USER` / `RTSP_PASSWORD` | – | The `RTSP_URL` camera's login, as typed. They are percent-encoded into the URL for you. See [Camera logins](#camera-logins). |
| `CAMERA_<N>_URL` / `_NAME` / `_TYPE` / `_DEVICE` | – | Define up to 8 cameras (`N`=1..8; `_TYPE`=`rtsp`\|`local`). A local camera needs only `_DEVICE`. One with nothing usable is skipped with a warning. |
| `CAMERA_<N>_USER` / `_PASSWORD` | – | That camera's login, as typed, percent-encoded into `CAMERA_<N>_URL` for you. |
| `CAMERAS_RESET` | `false` | `true` rebuilds `cameras.json` from the environment only, dropping cameras added in the UI. See [Cameras](#cameras). |
| `ENABLE_USB` | `false` | Add a `/dev/video0` local camera and load `uvcvideo` (+ `linux-modules-extra`). |
| `TLS_MODE` | `internal` | `none` (HTTP) \| `internal` (self-signed) \| `auto` (Let's Encrypt). `auto` needs `FQDN` set to a public name for this host, and refuses without it. |
| `AUTH_MODE` | `basic` | `none` \| `basic`. |
| `ADMIN_USER` / `ADMIN_PASSWORD` | `admin` / `changeme` | Basic-auth login. **Change the password.** Any password of up to 128 printable characters works as typed. The user name takes letters, digits and `. _ @ + -`. A re-run without them keeps the stored login; only a first install with no `ADMIN_PASSWORD` gets `changeme`. An empty `ADMIN_PASSWORD` is refused. See [Security](#security). |
| `TCP_PORT` | `443` (or `80` if `TLS_MODE=none`) | Listen port. |
| `MGMT_IP` / `FQDN` | auto | Bind IP / FQDN for TLS. |
| `FEATURE_TAGS/OBJECTS/CAPTION/PEOPLE/DENSE/OCR/BRANDS/COLOR` | tags/objects/caption=`true`, rest `false` | Default inference toggles. |
| `DRAW_BOXES` / `CONFIDENCE` | `true` / `0.5` | Box overlay + confidence threshold. |
| `AUTO_ANALYZE` / `AUTO_INTERVAL` | `false` / `300` | Interval auto-analyze (seconds). |
| `KEYWORD_WATCH` / `KEYWORD_TERMS` | `false` / – | Watch + comma-separated terms. |
| `KEYWORD_SOUND` / `KEYWORD_NOTIFY` | `true` / `false` | Alert sound / desktop notification. |
| `SNAPSHOTS` / `SNAPSHOTS_ON_DETECTION` | `false` / `false` | Save snapshots / only on keyword match. |
| `CADDY_VERSION` | `2.11.4` | Pinned Caddy binary version. |
| `APP_DIR` / `APP_USER` | `/opt/object_detector_web_app` / `acvuser` | Install dir / service user. |
| `PERSIST_DIR` | `/var/lib/object_detector_web` | Where the monthly transaction tally is stored — **outside `APP_DIR` so it survives re-installs/redeploys**. |
| `PURGE` | `false` | On uninstall, also delete state + snapshots + the persisted budget. |

## Cameras

Define cameras at install via `RTSP_URL` or `CAMERA_<N>_*`, or manage them live in the **🎥 Cameras** modal:

- **RTSP/network** — paste an `rtsp://…` URL, and type the camera's user and password in their own fields.
- **USB/local** — **Scan** auto-discovers `/dev/video*` devices (needs `ENABLE_USB=true` at install so `uvcvideo` is loaded).

**Re-running `deploy.sh` keeps the cameras you added in the UI.** Cameras the environment defines are marked
`"source": "env"` in `cameras.json`. On every run they are replaced by what the environment defines then, and every
other camera stays:

- Clearing `RTSP_URL`, or setting `ENABLE_USB=false`, removes that camera, as before.
- If a UI camera and an environment camera have the same id (`cam1`, `cam2`… or `usb0`), the environment's wins.
- A camera you delete in the UI comes back on the next run if the environment still defines it.
- `CAMERAS_RESET=true` rebuilds the file from the environment only, as releases before 1.1.0 did on every run.
- A `cameras.json` from before 1.1.0 has no `source` field, so its environment cameras look like UI ones. Its `cam1`
  and `usb0` are replaced as usual, because the environment uses those ids. If the first run after upgrading also
  clears `RTSP_URL`, the old `cam1` stays: delete it in the UI, or use `CAMERAS_RESET=true`.

A full `uninstall` still removes `cameras.json`, UI cameras included.

### Camera logins

Give a camera's user and password in their own settings: `RTSP_USER` / `RTSP_PASSWORD` for `RTSP_URL`,
`CAMERA_<N>_USER` / `CAMERA_<N>_PASSWORD` for `CAMERA_<N>_URL`, or the **User** and **Password** fields of the
**Add a Camera** form. They are used exactly as typed, symbols and spaces included. The installer and the app
percent-encode them into the URL (every byte but `A-Z a-z 0-9 - . _ ~` becomes `%XX`), and FFmpeg decodes them
before it logs in, under Basic and Digest auth alike.

- **A URL with the login already inside it works as before.** It is stored as given, so any symbol in the password
  must already be percent-encoded: a `/`, `?` or `#` left as typed stops the camera from connecting, and a `%`
  followed by two hex digits is read as an encoded byte. To encode a password by hand, run this and type the password:

  ```bash
  python3 -c 'import sys, urllib.parse as u; print(u.quote(sys.stdin.readline().rstrip("\n"), safe=""))'
  ```

  `p@ss/w#rd` becomes `p%40ss%2Fw%23rd`, so the URL is `rtsp://viewer:p%40ss%2Fw%23rd@192.168.1.50:554/stream`.
- **Refused, with a message that names the setting but never shows the value:** a user with a `:` (a camera
  login splits the user from the password there); a password without a user; a control character; a URL that has a
  login inside it *and* a separate user or password; and, for an RTSP camera, a user and password that take more than
  127 bytes once encoded (`user:password`). FFmpeg reads at most 127 and silently cuts the rest off. Each symbol or
  space takes 3 bytes: with a user such as `viewer`, a password of 40 symbols fits, or one of 120 letters and digits.
- **Passwords are never shown.** The **Manage Cameras** list and `GET /api/cameras` show each one as `***`
  (`rtsp://viewer:***@…`). `cameras.json`, which holds them, is mode `0600`, readable only by the app's user and root.

### Runtime settings on a re-run

`state/config.json` holds the inference and Azure settings (`FEATURE_*`, `DRAW_BOXES`, `CONFIDENCE`, `AUTO_*`,
`KEYWORD_*`, `SNAPSHOTS*`, `AZURE_API_VERSION`, `AZURE_MONTHLY_BUDGET`, `AZURE_BUDGET_MODE`), which the UI can change too.
A first install writes them all. **A re-run applies the ones you pass, and keeps the rest:** a setting you don't pass
keeps its value, including a change made in the UI. A setting you pass replaces it, and the run names what it changed.
The banner shows the values the file holds, which are the ones the app uses.

> **USB cameras inside a VM:** raw hypervisor USB passthrough often cannot stream a webcam's
> isochronous video into a guest. If a passed-through camera enumerates but never delivers
> frames, run the camera on a host where it works natively and publish it as RTSP (e.g.
> `mediamtx` + `ffmpeg`), then add that RTSP URL here.

## Azure AI Vision & the free tier

### Setting up Azure Computer Vision (get your key + endpoint)

This app needs an Azure Computer Vision resource to run analysis. The **F0 free tier** costs
nothing (it throttles instead of billing). High-level steps:

1. **Sign up for Azure.** Go to <https://azure.microsoft.com> and create a free account if you
   don't have one (a credit card is required for identity verification, but the F0 tier below
   does not bill — see the note further down).
2. **Sign in to the Azure portal** at <https://portal.azure.com>.
3. **Search for "Computer Vision"** in the top search bar and open it (under *Marketplace* /
   *Azure AI services*). It may also be listed as **Azure AI Vision**.
4. **Click *Create*** and fill in the basics:
   - **Subscription** — your subscription.
   - **Resource group** — create a new one (e.g. `object-detector`) or pick an existing one.
   - **Region** — pick one close to you.
   - **Name** — a unique name (this becomes part of your endpoint URL).
   - **Pricing tier** — select **Free F0** (5,000 transactions/month). If F0 is greyed out you
     may already have a free Computer Vision resource on the subscription — only one F0 is
     allowed per subscription.
   - Accept the Responsible AI notice, then **Review + create → Create** and wait for deployment.
5. **Obtain the key and endpoint.** Open the new resource → **Keys and Endpoint** (left menu).
   Copy **KEY 1** and the **Endpoint** URL
   (`https://<your-resource-name>.cognitiveservices.azure.com/`).
6. **Plug them into the deploy** as `AZURE_VISION_KEY` and `AZURE_VISION_ENDPOINT` (see
   [Quick start](#quick-start)). You can rotate keys anytime from this same page.

### Notes on cost & usage

- The app targets the **F0 free tier: 5,000 transactions/month, 20/min** — F0 throttles (HTTP 429)
  rather than billing, so it **cannot incur cost**. Only the S1 (Standard) tier bills.
- **Each enabled feature = one transaction.** The Settings drawer shows a live
  "*N transactions/call → ~X free frames/month*" estimate, and the header shows usage vs. the monthly cap.
- Auto-analyze is **off by default**; when on, the budget guard auto-pauses near the cap and the UI
  suggests a safe interval. Continuous per-second cloud analysis is not free — keep intervals generous.
- **The meter resets itself automatically at the start of each UTC calendar month** (matching how the F0
  quota resets) — no restart needed. The tally is stored in `PERSIST_DIR` (default
  `/var/lib/object_detector_web/budget.json`), **outside `APP_DIR`, so re-installing or redeploying does
  not zero your usage for the month.** A full `PURGE=true` uninstall does clear it.
  > The meter counts what *this app* sent; it does not see usage from the Azure portal or other apps
  > sharing the same key. For the authoritative resource-wide figure, see the **`ComputerVisionTransactions`**
  > metric in Azure Monitor (requires Azure AD / a Monitoring Reader role, not the Vision key).
- API `v4` provides caption (region-dependent), objects, people, dense captions, OCR. `v3.2` adds Brands/Color.

## Security

- **Caddy** terminates optional self-signed TLS (`TLS_MODE=internal`) and **basic auth** (`AUTH_MODE=basic`).
  `/healthz` is exempt from auth.
- **The admin login is hashed with argon2id,** so a password of any length up to 128 characters works (bcrypt, before
  1.2.0, stopped at 72 bytes). Caddy reads the password on stdin, never from a command line. `/etc/caddy/admin-login`
  (mode `0600`) keeps the user, the hash and a fingerprint of the password it was made from:
  - a re-run without `ADMIN_PASSWORD` keeps the login as it is, and one without `ADMIN_USER` keeps the user;
  - a re-run with the same password keeps the same hash, so the Caddyfile doesn't change;
  - a new password is hashed again;
  - an empty `ADMIN_PASSWORD`, a control character, more than 128 characters, or a user name with anything but
    letters, digits and `. _ @ + -` is refused before anything is stopped or changed.

  The first run of 1.2.0 over an older install keeps that install's bcrypt login when no `ADMIN_PASSWORD` is passed,
  and moves to argon2id when one is. The installer never prints the password. `uninstall` removes the stored login.
- Azure credentials are stored in a `chmod 600` `EnvironmentFile`, not in the systemd unit. Their values are written
  in double quotes with `\ " $` and `` ` `` escaped, so systemd reads them back exactly.
- Camera passwords are shown as `***` in the UI and the API, and `cameras.json` is mode `0600`. See
  [Camera logins](#camera-logins).
- The web app binds only to a local unix socket; Caddy is the sole network listener.
- **Change `ADMIN_PASSWORD`** from the default.

## Air-gapped install

On an internet-connected machine of the **same OS family / arch / Python version** as the target:

```bash
sudo ./deploy.sh save        # builds od-save.tar.gz (OS pkgs + wheels + Caddy)
```

Copy the **whole repo dir** (`deploy.sh`, `app/`, `camera_unavailable.jpg`) **and `od-save.tar.gz`**
to the air-gapped host, then:

```bash
sudo AZURE_VISION_KEY=... AZURE_VISION_ENDPOINT=... ./deploy.sh install
```

`install` auto-detects the bundle and installs with **no internet** (OS packages via the bundled
install-packages file-repo, Python deps from bundled wheels, Caddy from the bundled binary).
*(Note: Azure analysis itself still needs network access to Azure; the live multi-camera display works fully offline.)*

## How it works

- **`camera_supervisor.py`** (`od-cameras.service`) — one capture thread per camera writing 1280×720 frames
  into per-camera POSIX shared memory; reloads `cameras.json` on `SIGHUP`.
- **`app.py`** (`od-web.service`, gunicorn + gevent) — serves the UI, per-camera MJPEG, the REST API, and the
  auto-analyze loop; reads frames from shared memory and calls Azure via a pluggable analyzer.
- **Caddy** (`od-caddy.service`) — reverse-proxy with TLS + basic auth.

## Uninstall

```bash
sudo ./deploy.sh uninstall              # keeps state + snapshots
sudo PURGE=true ./deploy.sh uninstall   # removes everything
```

---

## Upstream / Credits

This is an original application that builds on the following open-source projects and services — all credit for
those components goes to their authors:

- [Caddy](https://github.com/caddyserver/caddy) — web server / reverse proxy (Apache-2.0)
- [Flask](https://github.com/pallets/flask) (BSD-3-Clause) + [Gunicorn](https://github.com/benoitc/gunicorn) (MIT) + [gevent](https://github.com/gevent/gevent) (MIT) — web app + WSGI server
- [OpenCV](https://github.com/opencv/opencv) (`opencv-python-headless`, Apache-2.0) + [NumPy](https://github.com/numpy/numpy) (BSD-3-Clause) — frame capture/processing
- [Azure AI Vision SDKs](https://github.com/Azure/azure-sdk-for-python) (MIT) — client libraries for the **Azure AI Vision** cloud service (a proprietary Microsoft service; you bring your own key)
- [FFmpeg](https://ffmpeg.org/) — used via the OS package for RTSP decoding (license depends on the distro build). On RHEL and Rocky it is in RPM Fusion, not the default repos, so the install and `save` go on without it there

## License

Licensed under the **Apache License 2.0** — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
