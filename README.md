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
     RTSP_URL="rtsp://user:pass@192.168.1.50:554/stream" \
     ADMIN_PASSWORD="change-me" \
     ./deploy.sh
```

Then open `https://<server-ip>/` and log in as `admin` / `<ADMIN_PASSWORD>`.
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
| `CAMERA_<N>_URL` / `_NAME` / `_TYPE` / `_DEVICE` | – | Define up to 8 cameras (`N`=1..8; `_TYPE`=`rtsp`\|`local`). |
| `ENABLE_USB` | `false` | Add a `/dev/video0` local camera and load `uvcvideo` (+ `linux-modules-extra`). |
| `TLS_MODE` | `internal` | `none` (HTTP) \| `internal` (self-signed) \| `auto` (Let's Encrypt). |
| `AUTH_MODE` | `basic` | `none` \| `basic`. |
| `ADMIN_USER` / `ADMIN_PASSWORD` | `admin` / `changeme` | Basic-auth credentials. **Change the password.** |
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

- **RTSP/network** — paste an `rtsp://…` URL.
- **USB/local** — **Scan** auto-discovers `/dev/video*` devices (needs `ENABLE_USB=true` at install so `uvcvideo` is loaded).

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

- **Caddy** terminates optional self-signed TLS (`TLS_MODE=internal`) and **basic auth** (`AUTH_MODE=basic`,
  bcrypt-hashed). `/healthz` is exempt from auth.
- Azure credentials are stored in a `chmod 600` `EnvironmentFile`, not in the systemd unit.
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
- [FFmpeg](https://ffmpeg.org/) — used via the OS package for RTSP decoding (license depends on the distro build)

## License

Licensed under the **Apache License 2.0** — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
