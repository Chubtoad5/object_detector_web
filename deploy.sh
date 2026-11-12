#!/bin/bash
# =============================================================================
# Object Detector Web - all-in-one installer
#   Containerless: Caddy (binary) + Python venv + systemd.
#   Commands: install (default) | uninstall | status | version | help
#   All variables below are runtime-overridable:  sudo VAR=value ./deploy.sh
# =============================================================================
set -e
SCRIPT_VERSION="1.2.0"

# The runtime settings state/config.json holds. Recorded before the defaults below fill them in: on a re-run, one the
# caller passed replaces the kept value, and one it didn't pass keeps whatever the file (or the UI) has.
RUNTIME_SETTINGS="FEATURE_TAGS FEATURE_OBJECTS FEATURE_CAPTION FEATURE_PEOPLE FEATURE_DENSE FEATURE_OCR FEATURE_BRANDS FEATURE_COLOR DRAW_BOXES CONFIDENCE AUTO_ANALYZE AUTO_INTERVAL KEYWORD_WATCH KEYWORD_TERMS KEYWORD_SOUND KEYWORD_NOTIFY SNAPSHOTS SNAPSHOTS_ON_DETECTION AZURE_API_VERSION AZURE_MONTHLY_BUDGET AZURE_BUDGET_MODE"
PASSED_SETTINGS=""
for _setting in $RUNTIME_SETTINGS; do
  [ -n "${!_setting:-}" ] && PASSED_SETTINGS="$PASSED_SETTINGS $_setting"
done
FQDN_GIVEN="${FQDN:-}"
# O11 (spec 21): whether the caller passed the admin login, recorded before the defaults below. A re-run without
# ADMIN_PASSWORD keeps the stored login, and an empty one is refused. Only a first install with none gets changeme.
ADMIN_PASSWORD_SET="${ADMIN_PASSWORD+set}"
ADMIN_USER_GIVEN="${ADMIN_USER:-}"

# ----------------------------------------------------------------- config
# --- Azure Computer Vision (Image Analysis) ---
AZURE_VISION_KEY="${AZURE_VISION_KEY:-YOUR_AZURE_KEY_HERE}"
AZURE_VISION_ENDPOINT="${AZURE_VISION_ENDPOINT:-YOUR_AZURE_ENDPOINT_HERE}"
AZURE_API_VERSION="${AZURE_API_VERSION:-v4}"            # v4 | v3.2
AZURE_MONTHLY_BUDGET="${AZURE_MONTHLY_BUDGET:-4500}"    # free F0 cap is 5000 tx/mo
AZURE_BUDGET_MODE="${AZURE_BUDGET_MODE:-soft}"          # soft (warn) | hard (block)

# --- Cameras (RTSP_URL = convenience single cam; or CAMERA_1_URL .. CAMERA_8_URL) ---
# A camera's login goes in RTSP_USER / RTSP_PASSWORD (or CAMERA_<N>_USER / _PASSWORD), percent-encoded into the URL
# for you; or inside the URL, already encoded, as before.
RTSP_URL="${RTSP_URL:-}"
RTSP_USER="${RTSP_USER:-}"
RTSP_PASSWORD="${RTSP_PASSWORD:-}"
ENABLE_USB="${ENABLE_USB:-false}"                       # true => add a /dev/video0 local camera
USB_KERNEL_TRACK="${USB_KERNEL_TRACK:-true}"            # ENABLE_USB only: keep uvcvideo across kernel upgrades
CAMERAS_RESET="${CAMERAS_RESET:-false}"                 # true => cameras.json is rebuilt from the environment only, dropping cameras added in the UI

# --- Web / TLS / auth ---
TLS_MODE="${TLS_MODE:-internal}"                        # none | internal (self-signed) | auto (LE)
AUTH_MODE="${AUTH_MODE:-basic}"                         # none | basic
ADMIN_USER="${ADMIN_USER:-admin}"                       # a re-run without it keeps the stored user
ADMIN_PASSWORD="${ADMIN_PASSWORD-}"                     # first install without it: changeme; a re-run keeps the stored one
MGMT_IP="${MGMT_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
FQDN="${FQDN:-od.$(hostname -f 2>/dev/null || hostname)}"
if [ "$TLS_MODE" = "none" ]; then TCP_PORT="${TCP_PORT:-80}"; else TCP_PORT="${TCP_PORT:-443}"; fi

# --- Inference feature defaults (UI-overridable at runtime) ---
FEATURE_TAGS="${FEATURE_TAGS:-true}"
FEATURE_OBJECTS="${FEATURE_OBJECTS:-true}"
FEATURE_CAPTION="${FEATURE_CAPTION:-true}"
FEATURE_PEOPLE="${FEATURE_PEOPLE:-false}"
FEATURE_DENSE="${FEATURE_DENSE:-false}"
FEATURE_OCR="${FEATURE_OCR:-false}"
FEATURE_BRANDS="${FEATURE_BRANDS:-false}"
FEATURE_COLOR="${FEATURE_COLOR:-false}"
DRAW_BOXES="${DRAW_BOXES:-true}"
CONFIDENCE="${CONFIDENCE:-0.5}"
AUTO_ANALYZE="${AUTO_ANALYZE:-false}"
AUTO_INTERVAL="${AUTO_INTERVAL:-300}"
KEYWORD_WATCH="${KEYWORD_WATCH:-false}"
KEYWORD_TERMS="${KEYWORD_TERMS:-}"
KEYWORD_SOUND="${KEYWORD_SOUND:-true}"
KEYWORD_NOTIFY="${KEYWORD_NOTIFY:-false}"
SNAPSHOTS="${SNAPSHOTS:-false}"
SNAPSHOTS_ON_DETECTION="${SNAPSHOTS_ON_DETECTION:-false}"

# --- Paths / runtime ---
APP_USER="${APP_USER:-acvuser}"
APP_DIR="${APP_DIR:-/opt/object_detector_web_app}"
PERSIST_DIR="${PERSIST_DIR:-/var/lib/object_detector_web}"  # monthly tx tally; survives re-install
CADDY_VERSION="${CADDY_VERSION:-2.11.4}"
PURGE="${PURGE:-false}"                                 # uninstall: also delete snapshots/state/budget

# --- Air-gap ---
OFFLINE_SENTINEL="${OFFLINE_SENTINEL:-od-save.tar.gz}"  # presence next to deploy.sh => offline install
INSTALL_PKGS_URL="${INSTALL_PKGS_URL:-https://raw.githubusercontent.com/Chubtoad5/install-packages/main/install_packages.sh}"
LICENSE_OFFER_CONTACT="${LICENSE_OFFER_CONTACT:-the Chubtoad5 project via https://github.com/Chubtoad5}"  # contact named in the air-gap bundle's GPL written offer
AIR_GAPPED_MODE=0
OFFLINE_DIR=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# Where the Caddy binary and its config live. Fixed, not settings: tests point them at a stub and a temp folder.
CADDY_BIN=/usr/local/bin/caddy
CADDY_DIR=/etc/caddy

# ----------------------------------------------------------------- helpers
step(){ echo "--- $* ---"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
require_root(){ [ "$(id -u)" -eq 0 ] || die "must be run as root (use sudo)."; }

detect_distro(){
  [ -r /etc/os-release ] || die "/etc/os-release not found; cannot detect OS."
  . /etc/os-release
  OS_ID="${ID:-}"
  case "$OS_ID" in
    ubuntu|debian) PKG=apt ;;
    rhel|centos|rocky|almalinux|fedora) PKG=dnf ;;
    sles|opensuse-leap) PKG=zypper ;;
    *) die "unsupported OS '${OS_ID:-unknown}'. Supported: Ubuntu/Debian, RHEL family, SLES." ;;
  esac
  echo "  Detected ${PRETTY_NAME:-$OS_ID} (pkg: $PKG)"
}

is_offline(){ [ -f "$SCRIPT_DIR/$OFFLINE_SENTINEL" ]; }

# Runtime OS packages this app needs (per distro). Used by online install,
# offline install (via install-packages), and the air-gap save bundle.
os_pkg_list(){
  case "$PKG" in
    apt)    echo "python3-venv python3-pip ffmpeg libglib2.0-0t64 libgl1" ;;
    dnf)    echo "python3 python3-pip ffmpeg mesa-libGL glib2" ;;
    zypper) echo "python3 python3-pip ffmpeg Mesa-libGL1 glib2" ;;
  esac
}

# The OS packages save bundles. On dnf, ffmpeg is often in no enabled repo (RHEL and Rocky have it in RPM Fusion): leave it
# out and say so, as the online install does (spec 15, F3). The camera feed doesn't need it: OpenCV's wheel brings its
# own FFmpeg libraries.
save_pkg_list(){
  local p out=""
  for p in $(os_pkg_list); do
    if [ "$p" = ffmpeg ] && [ "$PKG" = dnf ] && [ -z "$(dnf -q repoquery --available ffmpeg 2>/dev/null)" ]; then
      echo "  NOTE: no enabled repo has ffmpeg (RHEL and Rocky have it in RPM Fusion), so the bundle leaves it out, as the online install does." >&2
      continue
    fi
    out="$out $p"
  done
  echo "${out# }"
}

# The OS packages the extracted bundle holds, from its manifest. A bundle without that line gets this distro's full list.
bundle_pkg_list(){
  local listed=""
  [ -f "$OFFLINE_DIR/save-manifest.txt" ] && listed=$(sed -n 's/^os_packages: //p' "$OFFLINE_DIR/save-manifest.txt")
  if [ -n "$listed" ]; then echo "$listed"; else os_pkg_list; fi
}

caddy_arch(){
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7l) echo armv7 ;;
    *) die "unsupported CPU arch $(uname -m) for Caddy binary." ;;
  esac
}
caddy_url(){ echo "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_$(caddy_arch).tar.gz"; }

# uvcvideo (the USB Video Class driver that creates /dev/video0) ships in
# linux-modules-extra-<kver> on Debian/Ubuntu, which the 'virtual'/cloud kernel
# flavors omit. Install it for EVERY installed kernel image -- not just $(uname -r)
# -- so a kernel apt has already pulled but not yet booted is covered too. Then
# (default) track the linux-image-<flavor> meta, whose modules-extra dependency is
# re-pulled on every future kernel bump: this is what stops an unattended kernel
# upgrade + reboot from silently killing /dev/video0. Loud (not silenced), never fatal.
usb_install_extra_modules_apt(){
  local kvers kver flavor
  kvers="$(ls /boot/vmlinuz-* 2>/dev/null | sed 's#.*/vmlinuz-##' | sort -uV)"
  [ -n "$kvers" ] || kvers="$(uname -r)"
  for kver in $kvers; do
    echo "  Installing uvcvideo driver: linux-modules-extra-$kver"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "linux-modules-extra-$kver" \
      || echo "  WARNING: linux-modules-extra-$kver unavailable; USB camera will not work on that kernel."
  done
  if [ "${USB_KERNEL_TRACK,,}" = "true" ]; then
    flavor="$(uname -r | sed -E 's/^[0-9.]+-[0-9]+-//')"
    if [ -n "$flavor" ]; then
      echo "  Tracking uvcvideo across future kernels: linux-image-$flavor"
      DEBIAN_FRONTEND=noninteractive apt-get install -y "linux-image-$flavor" \
        || echo "  NOTE: could not install linux-image-$flavor; future kernel upgrades may drop uvcvideo (set USB_KERNEL_TRACK=false to silence)."
    fi
  fi
  return 0
}

# Load uvcvideo and confirm it is actually present for the RUNNING kernel. A missing
# driver is the #1 cause of "camera plugged in but no /dev/video0", and the old code
# swallowed it silently -- here we warn unmissably (but keep going: RTSP cameras and
# the rest of the app do not need it).
usb_verify_driver(){
  local flavor; flavor="$(uname -r | sed -E 's/^[0-9.]+-[0-9]+-//')"
  modprobe uvcvideo 2>/dev/null || true
  if modinfo uvcvideo >/dev/null 2>&1 && lsmod | grep -q '^uvcvideo'; then
    echo "  uvcvideo loaded for kernel $(uname -r)."
    local newest; newest="$(ls /boot/vmlinuz-* 2>/dev/null | sed 's#.*/vmlinuz-##' | sort -V | tail -1)"
    if [ -n "$newest" ] && [ "$newest" != "$(uname -r)" ]; then
      echo "  NOTE: newer kernel '$newest' is installed; a reboot will switch to it."
      [ "$PKG" = "apt" ] && echo "        (its modules-extra was installed too, so the camera should keep working.)"
    fi
    return 0
  fi
  echo "  ============================ USB CAMERA WARNING ============================"
  echo "  uvcvideo is NOT loaded for the running kernel ($(uname -r))."
  echo "  /dev/video0 will not appear; the local USB camera will NOT work."
  echo "  Likely cause: the running kernel has no extra-modules package, or a kernel"
  echo "  upgrade is pending a reboot. Remediate, then re-deploy with ENABLE_USB=true:"
  if [ "$PKG" = "apt" ]; then
    echo "      apt-get install -y linux-modules-extra-\$(uname -r)   # for this kernel"
    echo "      apt-get install -y linux-image-${flavor:-generic}   # track future kernel upgrades"
  else
    echo "      install the kernel-modules package matching $(uname -r), then: modprobe uvcvideo"
  fi
  echo "  RTSP cameras are unaffected. Continuing deploy."
  echo "  ==========================================================================="
}

install_os_packages(){
  if [ "$AIR_GAPPED_MODE" -eq 1 ]; then
    step "Installing OS packages (offline bundle)"
    [ -f "$OFFLINE_DIR/install_packages.sh" ] && [ -f "$OFFLINE_DIR/offline-packages.tar.gz" ] \
      || die "offline bundle is missing OS packages (install_packages.sh / offline-packages.tar.gz)"
    chmod +x "$OFFLINE_DIR/install_packages.sh"
    # shellcheck disable=SC2046 # one word per package
    ( cd "$OFFLINE_DIR" && ./install_packages.sh offline $(bundle_pkg_list) )
    if [ "${ENABLE_USB,,}" = "true" ]; then usb_verify_driver; fi
    return
  fi
  step "Installing OS packages"
  case "$PKG" in
    apt)
      apt-get update -qq
      DEBIAN_FRONTEND=noninteractive apt-get install -y python3-venv python3-pip ffmpeg curl tar >/dev/null
      apt-get install -y libglib2.0-0t64 >/dev/null 2>&1 || apt-get install -y libglib2.0-0 >/dev/null 2>&1 || true
      apt-get install -y libgl1 >/dev/null 2>&1 || apt-get install -y libgl1-mesa-glx >/dev/null 2>&1 || true
      if [ "${ENABLE_USB,,}" = "true" ]; then
        usb_install_extra_modules_apt
        usb_verify_driver
      fi ;;
    dnf)
      echo "  NOTE: RHEL family is structurally supported but ffmpeg may require RPM Fusion (Phase 2 validation)."
      dnf install -y python3 python3-pip ffmpeg curl tar mesa-libGL glib2 >/dev/null 2>&1 || \
        dnf install -y python3 python3-pip curl tar glib2 >/dev/null
      if [ "${ENABLE_USB,,}" = "true" ]; then usb_verify_driver; fi ;;
    zypper)
      echo "  NOTE: SLES is structurally supported but not yet smoke-tested (Phase 2 validation)."
      zypper --non-interactive install python3 python3-pip ffmpeg curl tar Mesa-libGL1 glib2 >/dev/null 2>&1 || \
        zypper --non-interactive install python3 python3-pip curl tar glib2 >/dev/null
      if [ "${ENABLE_USB,,}" = "true" ]; then usb_verify_driver; fi ;;
  esac
}

install_caddy(){
  step "Installing Caddy ${CADDY_VERSION} (binary)"
  if command -v caddy >/dev/null 2>&1 && caddy version 2>/dev/null | grep -q "v${CADDY_VERSION}"; then
    echo "  Caddy v${CADDY_VERSION} already present."
    return
  fi
  if [ "$AIR_GAPPED_MODE" -eq 1 ]; then
    [ -f "$OFFLINE_DIR/caddy" ] || die "offline bundle is missing the caddy binary."
    install -m 0755 "$OFFLINE_DIR/caddy" /usr/local/bin/caddy
    echo "  Installed from bundle: $(/usr/local/bin/caddy version | head -1)"
    return
  fi
  local tmp; tmp="$(mktemp -d)"
  echo "  Downloading $(caddy_url)"
  curl -fsSL "$(caddy_url)" -o "$tmp/caddy.tar.gz" || die "Caddy download failed (no internet? build a bundle with: ./deploy.sh save)."
  tar xzf "$tmp/caddy.tar.gz" -C "$tmp" caddy
  install -m 0755 "$tmp/caddy" /usr/local/bin/caddy
  rm -rf "$tmp"
  echo "  Installed: $(/usr/local/bin/caddy version | head -1)"
}

create_user_dirs(){
  step "Creating app user and directories"
  if id "$APP_USER" >/dev/null 2>&1; then echo "  user $APP_USER exists"; else
    useradd -r -s /bin/false "$APP_USER"; echo "  created user $APP_USER"; fi
  usermod -a -G video "$APP_USER" 2>/dev/null || true
  mkdir -p "$APP_DIR"/{templates,static,state,snapshots}
  chmod 755 "$APP_DIR"
  # Persistent budget store outside APP_DIR so the monthly tx tally survives re-installs.
  mkdir -p "$PERSIST_DIR"
  # Migrate a pre-1.0.3 in-APP_DIR budget so existing hosts keep their running count.
  if [ ! -f "$PERSIST_DIR/budget.json" ] && [ -f "$APP_DIR/state/budget.json" ]; then
    cp "$APP_DIR/state/budget.json" "$PERSIST_DIR/budget.json"
    echo "  migrated existing budget.json -> $PERSIST_DIR"
  fi
}

copy_app_files(){
  step "Installing application files"
  [ -d "$SCRIPT_DIR/app" ] || die "app/ directory not found next to deploy.sh"
  cp "$SCRIPT_DIR/app/analyzer.py" "$SCRIPT_DIR/app/camera_supervisor.py" "$SCRIPT_DIR/app/app.py" \
     "$SCRIPT_DIR/app/camera_url.py" "$APP_DIR/"
  cp "$SCRIPT_DIR/app/requirements.txt" "$APP_DIR/"
  cp "$SCRIPT_DIR/app/templates/index.html" "$APP_DIR/templates/"
  if [ -f "$SCRIPT_DIR/camera_unavailable.jpg" ]; then
    cp "$SCRIPT_DIR/camera_unavailable.jpg" "$APP_DIR/static/"
  else
    echo "  WARNING: camera_unavailable.jpg not found; placeholder will be blank."
  fi
}

# cameras_py check|write <cameras.json>: the cameras the environment defines. "write" prints the cameras.json to store;
# "check" only checks them, for validate_inputs. A camera user or password that can't work is refused, one message
# per setting, and never shows the value (O8, spec 21). app/camera_url.py builds each URL, as the app does.
cameras_py(){
  local i
  export RTSP_URL RTSP_USER RTSP_PASSWORD ENABLE_USB CAMERAS_RESET
  for i in 1 2 3 4 5 6 7 8; do
    export "CAMERA_${i}_URL" "CAMERA_${i}_NAME" "CAMERA_${i}_TYPE" "CAMERA_${i}_DEVICE" "CAMERA_${i}_USER" "CAMERA_${i}_PASSWORD" 2>/dev/null || true
  done
  python3 -I - "$SCRIPT_DIR/app" "$@" <<'PYEOF'
import os, sys, json
sys.path.insert(0, sys.argv[1])
from camera_url import build_url, CredentialError
mode, path = sys.argv[2], sys.argv[3]
env = lambda k: os.environ.get(k, "").strip()
raw = lambda k: os.environ.get(k, "")   # a user or password is used exactly as given: spaces at either end included
errors = []
def warn(msg):
    if mode == "write":
        print("  WARNING: " + msg, file=sys.stderr)
def login_url(url_var, user_var, password_var):
    try:
        return build_url(env(url_var), raw(user_var), raw(password_var), (url_var, user_var, password_var))
    except CredentialError as e:
        errors.append(str(e))
        return None
mine = []
def add(cid, name, ctype, url=None, device=None):
    c = {"id": cid, "name": name, "type": ctype, "enabled": True, "source": "env"}
    if url: c["url"] = url
    if device: c["device"] = device
    mine.append(c)
explicit = False
for i in range(1, 9):
    u, d = env("CAMERA_%d_URL" % i), env("CAMERA_%d_DEVICE" % i)
    t = env("CAMERA_%d_TYPE" % i) or ("local" if d and not u else "rtsp")
    if not (u or d):
        if env("CAMERA_%d_TYPE" % i) or env("CAMERA_%d_NAME" % i) or raw("CAMERA_%d_USER" % i) or raw("CAMERA_%d_PASSWORD" % i):
            warn("CAMERA_%d is set, but has no CAMERA_%d_URL or CAMERA_%d_DEVICE, so it is skipped." % (i, i, i))
        continue
    if t == "rtsp" and not u:
        warn("CAMERA_%d_TYPE=rtsp needs CAMERA_%d_URL, so it is skipped." % (i, i))
        continue
    if u:
        u = login_url("CAMERA_%d_URL" % i, "CAMERA_%d_USER" % i, "CAMERA_%d_PASSWORD" % i)
        if u is None:
            continue
    explicit = True
    add("cam%d" % i, env("CAMERA_%d_NAME" % i) or "Camera %d" % i, t, url=u or None, device=d or None)
rtsp = env("RTSP_URL")
if rtsp and not explicit:
    rtsp = login_url("RTSP_URL", "RTSP_USER", "RTSP_PASSWORD")
    if rtsp:
        add("cam1", "RTSP Camera", "rtsp", url=rtsp)
elif not rtsp and (raw("RTSP_USER") or raw("RTSP_PASSWORD")):
    warn("RTSP_USER or RTSP_PASSWORD is set, but RTSP_URL isn't, so they are unused.")
if errors:
    for e in errors:
        print("  ERROR: " + e, file=sys.stderr)
    sys.exit(1)
if mode == "check":
    sys.exit(0)
if os.environ.get("ENABLE_USB", "false").lower() == "true":
    add("usb0", "USB Camera", "local", device="/dev/video0")
# A re-run keeps the cameras added in the UI. The environment's own cameras (source "env") are replaced by what it
# defines now, so clearing RTSP_URL still removes its camera, and on an id clash the environment wins.
kept = []
if os.environ.get("CAMERAS_RESET", "false").lower() != "true":
    try:
        with open(path) as f:
            old = json.load(f).get("cameras", [])
        if not isinstance(old, list):
            old = []
    except (OSError, ValueError, AttributeError):
        old = []
    ids = {c["id"] for c in mine}
    kept = [c for c in old if isinstance(c, dict) and c.get("source") != "env" and c.get("id") not in ids]
print(json.dumps({"cameras": mine + kept}, indent=2))
PYEOF
}

# check_cameras: the camera settings' check, for validate_inputs, before anything changes. A host with no python3 yet
# (a first install on a minimal image) gets the same check in write_cameras_json, still before the app is touched.
check_cameras(){
  command -v python3 >/dev/null 2>&1 || return 0
  cameras_py check "" || die "a camera setting can't work (above). Nothing was changed."
}

write_cameras_json(){
  step "Writing cameras.json"
  local out="$APP_DIR/cameras.json.new"
  # Mode 0600 from the start, since camera passwords are in it (O13). The app's user gets it before it's moved into
  # place, so the running app can still read it until the swap.
  ( umask 077; cameras_py write "$APP_DIR/cameras.json" > "$out" ) || { rm -f "$out"; die "couldn't build cameras.json (output above)."; }
  chown "$APP_USER:$APP_USER" "$out" 2>/dev/null || true
  mv -f "$out" "$APP_DIR/cameras.json"
  echo "  $(python3 -c 'import json;print(len(json.load(open("'"$APP_DIR"'/cameras.json"))["cameras"]))') camera(s) configured"
}

write_config_json(){
  local cfg="$APP_DIR/state/config.json"
  if [ -f "$cfg" ]; then step "Updating runtime config (state/config.json)"; else step "Writing default runtime config"; fi
  local name
  for name in $RUNTIME_SETTINGS PASSED_SETTINGS; do export "${name?}"; done
  python3 - "$cfg" > "$cfg.new" <<'PYEOF' || { rm -f "$cfg.new"; die "couldn't update state/config.json (output above). A passed setting may be malformed."; }
import os, sys, json
path = sys.argv[1]
b = lambda k, d: os.environ.get(k, "true" if d else "false").lower() == "true"
terms = lambda: [t.strip() for t in os.environ.get("KEYWORD_TERMS", "").split(",") if t.strip()]
# setting: (place in config.json, value from the environment)
settings = {
 "FEATURE_TAGS": (("features", "tags"), lambda: b("FEATURE_TAGS", 1)),
 "FEATURE_OBJECTS": (("features", "objects"), lambda: b("FEATURE_OBJECTS", 1)),
 "FEATURE_CAPTION": (("features", "caption"), lambda: b("FEATURE_CAPTION", 1)),
 "FEATURE_PEOPLE": (("features", "people"), lambda: b("FEATURE_PEOPLE", 0)),
 "FEATURE_DENSE": (("features", "dense"), lambda: b("FEATURE_DENSE", 0)),
 "FEATURE_OCR": (("features", "ocr"), lambda: b("FEATURE_OCR", 0)),
 "FEATURE_BRANDS": (("features", "brands"), lambda: b("FEATURE_BRANDS", 0)),
 "FEATURE_COLOR": (("features", "color"), lambda: b("FEATURE_COLOR", 0)),
 "DRAW_BOXES": (("draw_boxes",), lambda: b("DRAW_BOXES", 1)),
 "CONFIDENCE": (("confidence",), lambda: float(os.environ.get("CONFIDENCE", "0.5"))),
 "AUTO_ANALYZE": (("auto", "enabled"), lambda: b("AUTO_ANALYZE", 0)),
 "AUTO_INTERVAL": (("auto", "interval"), lambda: int(os.environ.get("AUTO_INTERVAL", "300"))),
 "KEYWORD_WATCH": (("keyword", "enabled"), lambda: b("KEYWORD_WATCH", 0)),
 "KEYWORD_TERMS": (("keyword", "terms"), terms),
 "KEYWORD_SOUND": (("keyword", "sound"), lambda: b("KEYWORD_SOUND", 1)),
 "KEYWORD_NOTIFY": (("keyword", "notify"), lambda: b("KEYWORD_NOTIFY", 0)),
 "SNAPSHOTS": (("snapshots", "enabled"), lambda: b("SNAPSHOTS", 0)),
 "SNAPSHOTS_ON_DETECTION": (("snapshots", "on_detection"), lambda: b("SNAPSHOTS_ON_DETECTION", 0)),
 "AZURE_API_VERSION": (("azure", "api_version"), lambda: os.environ.get("AZURE_API_VERSION", "v4")),
 "AZURE_MONTHLY_BUDGET": (("azure", "monthly_budget"), lambda: int(os.environ.get("AZURE_MONTHLY_BUDGET", "4500"))),
 "AZURE_BUDGET_MODE": (("azure", "budget_mode"), lambda: os.environ.get("AZURE_BUDGET_MODE", "soft")),
}
try:
    with open(path) as f:
        cfg = json.load(f)
except OSError:
    cfg = None
except ValueError:
    sys.exit("state/config.json isn't valid JSON. Fix it, or delete it to start from the defaults.")
if cfg is None:
    # A first install writes every setting, from the environment or its default, in the original layout.
    cfg = {
     "features": {"tags": b("FEATURE_TAGS", 1), "objects": b("FEATURE_OBJECTS", 1),
       "caption": b("FEATURE_CAPTION", 1), "people": b("FEATURE_PEOPLE", 0),
       "dense": b("FEATURE_DENSE", 0), "ocr": b("FEATURE_OCR", 0),
       "brands": b("FEATURE_BRANDS", 0), "color": b("FEATURE_COLOR", 0)},
     "draw_boxes": b("DRAW_BOXES", 1),
     "confidence": float(os.environ.get("CONFIDENCE", "0.5")),
     "auto": {"enabled": b("AUTO_ANALYZE", 0), "interval": int(os.environ.get("AUTO_INTERVAL", "300"))},
     "keyword": {"enabled": b("KEYWORD_WATCH", 0), "terms": terms(),
       "sound": b("KEYWORD_SOUND", 1), "notify": b("KEYWORD_NOTIFY", 0)},
     "snapshots": {"enabled": b("SNAPSHOTS", 0), "on_detection": b("SNAPSHOTS_ON_DETECTION", 0)},
     "ocr_panel": True,
     "events": {"enabled": True, "max": 100},
     "azure": {"api_version": os.environ.get("AZURE_API_VERSION", "v4"),
       "monthly_budget": int(os.environ.get("AZURE_MONTHLY_BUDGET", "4500")),
       "budget_mode": os.environ.get("AZURE_BUDGET_MODE", "soft")},
    }
else:
    # A re-run applies only what it was given: anything else, including changes made in the UI, stays.
    changed = []
    for name in os.environ.get("PASSED_SETTINGS", "").split():
        where, value = settings[name]
        node = cfg
        for key in where[:-1]:
            node = node.setdefault(key, {})
        new = value()
        if node.get(where[-1]) != new:
            changed.append("%s=%s" % (name, os.environ.get(name, "")))
        node[where[-1]] = new
    if changed:
        print("  NOTE: state/config.json was kept. Applied from the environment: %s" % ", ".join(changed), file=sys.stderr)
print(json.dumps(cfg, indent=2))
PYEOF
  mv -f "$cfg.new" "$cfg"
}

# config_value <key> [<key>...]: a value from state/config.json, by its key path, for the banner.
config_value(){
  python3 -c 'import json,sys
v = json.load(open(sys.argv[1]))
for k in sys.argv[2:]: v = v[k]
print(v)' "$APP_DIR/state/config.json" "$@" 2>/dev/null
}

# env_file_value <value>: the value as a systemd EnvironmentFile reads it back exactly: in double quotes, with \ " `
# and $ escaped (O12, spec 21). Unquoted, systemd dropped every \ and the spaces at either end, and a value ending in
# \ swallowed the next line.
env_file_value(){
  local v=$1
  v=${v//\\/\\\\}; v=${v//\"/\\\"}; v=${v//\`/\\\`}; v=${v//\$/\\\$}
  printf '"%s"' "$v"
}

write_azure_env(){
  step "Writing Azure credentials (mode 600)"
  ( umask 077
    printf 'AZURE_VISION_KEY=%s\nAZURE_VISION_ENDPOINT=%s\n' "$(env_file_value "$AZURE_VISION_KEY")" \
      "$(env_file_value "$AZURE_VISION_ENDPOINT")" > "$APP_DIR/azure.env" )
  chmod 600 "$APP_DIR/azure.env"
}

setup_venv(){
  step "Setting up Python virtualenv"
  [ -d "$APP_DIR/venv" ] || python3 -m venv "$APP_DIR/venv"
  if [ "$AIR_GAPPED_MODE" -eq 1 ]; then
    [ -d "$OFFLINE_DIR/wheels" ] || die "offline bundle is missing Python wheels."
    "$APP_DIR/venv/bin/pip" install --no-index --find-links "$OFFLINE_DIR/wheels" -r "$SCRIPT_DIR/app/requirements.txt" >/dev/null
  else
    "$APP_DIR/venv/bin/pip" install --upgrade pip >/dev/null
    "$APP_DIR/venv/bin/pip" install -r "$SCRIPT_DIR/app/requirements.txt" >/dev/null
  fi
  echo "  dependencies installed"
}

write_systemd(){
  step "Writing systemd units"
  cat > /etc/systemd/system/od-cameras.service <<EOF
[Unit]
Description=Object Detector Camera Supervisor
After=network-online.target
Wants=network-online.target

[Service]
User=$APP_USER
Group=video
WorkingDirectory=$APP_DIR
Environment=APP_DIR=$APP_DIR
Environment=STATE_DIR=$APP_DIR/state
ExecStart=$APP_DIR/venv/bin/python $APP_DIR/camera_supervisor.py
Restart=always
RestartSec=3
ReadWritePaths=/dev/shm

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/od-web.service <<EOF
[Unit]
Description=Object Detector Web App
After=network-online.target od-cameras.service
Wants=od-cameras.service

[Service]
User=$APP_USER
Group=$APP_USER
WorkingDirectory=$APP_DIR
Environment=APP_DIR=$APP_DIR
Environment=STATE_DIR=$APP_DIR/state
Environment=PERSIST_DIR=$PERSIST_DIR
Environment=PYTHONUNBUFFERED=1
EnvironmentFile=$APP_DIR/azure.env
ExecStart=$APP_DIR/venv/bin/gunicorn --chdir $APP_DIR --workers 1 --worker-class gevent --timeout 120 --bind unix:$APP_DIR/web.sock app:app
Restart=always
RestartSec=3
ReadWritePaths=/dev/shm $PERSIST_DIR

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/od-caddy.service <<EOF
[Unit]
Description=Object Detector Caddy front-end
After=network-online.target od-web.service
Wants=od-web.service

[Service]
ExecStart=/usr/local/bin/caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

# ----------------------------------------------------------------- admin login (O9-O11, spec 21)
# The login's user name: letters, digits and . _ @ + -, which the Caddyfile and basic auth carry as they are. Listed
# out, not [[:alnum:]] or A-Z, which can match other letters in some locales.
valid_admin_user(){
  [[ "$1" =~ ^[ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._@+-]+$ ]]
}

# login_fingerprint <hash> <password>: ties a stored hash to the password it was made from, as SeaweedFS's
# auth_fingerprint does. The password reaches sha256sum on stdin, never in its arguments.
login_fingerprint(){ printf '%s' "$1:$2" | sha256sum | cut -d' ' -f1; }

# read_stored_login: the login the last run left, as STORED_USER, STORED_ALGO, STORED_HASH and STORED_FP (all empty
# when there is none). From $CADDY_DIR/admin-login (0600), or else from the basic_auth block of a Caddyfile that 1.1.1
# or earlier wrote, so the first upgrade without ADMIN_PASSWORD keeps that login too: its bcrypt hash, until a
# password is passed. A stored login that doesn't fit today's rules counts as none.
read_stored_login(){
  STORED_USER="" STORED_ALGO="" STORED_HASH="" STORED_FP="" STORED_UNUSABLE=0
  local f="$CADDY_DIR/admin-login" line in_block=0 u h
  if [ -f "$f" ]; then
    STORED_USER=$(sed -n 's/^user=//p' "$f" | head -1)
    STORED_ALGO=$(sed -n 's/^algorithm=//p' "$f" | head -1)
    STORED_HASH=$(sed -n 's/^hash=//p' "$f" | head -1)
    STORED_FP=$(sed -n 's/^fingerprint=//p' "$f" | head -1)
  elif [ -f "$CADDY_DIR/Caddyfile" ]; then
    while IFS= read -r line; do
      if [ "$in_block" -eq 0 ]; then
        if [[ "$line" =~ ^[[:space:]]*basic_auth([[:space:]]+(bcrypt|argon2id))?[[:space:]]*\{[[:space:]]*$ ]]; then
          in_block=1; STORED_ALGO=${BASH_REMATCH[2]:-bcrypt}
        fi
        continue
      fi
      [[ "$line" =~ ^[[:space:]]*\} ]] && break
      read -r u h _ <<< "$line"
      if [ -n "$u" ] && [ -n "$h" ]; then STORED_USER=$u STORED_HASH=$h; break; fi
    done < "$CADDY_DIR/Caddyfile"
  fi
  if ! valid_admin_user "$STORED_USER" || [[ ! "$STORED_ALGO" =~ ^(bcrypt|argon2id)$ ]] \
     || [[ ! "$STORED_HASH" =~ ^\$[!-~]+$ ]]; then
    # Something was stored, but this release can't use it: say so, rather than go back to changeme (rule 6)
    [ -n "$STORED_USER$STORED_HASH" ] && STORED_UNUSABLE=1
    STORED_USER="" STORED_ALGO="" STORED_HASH="" STORED_FP=""
  fi
}

# check_admin_login: the admin login's checks, for validate_inputs, before anything changes (rule 7). Sets ADMIN_USER
# to the user the login will have: the one passed, else the stored one, else admin.
check_admin_login(){
  [ "$AUTH_MODE" = "basic" ] || return 0
  if [ -n "$ADMIN_PASSWORD_SET" ] && [ -z "$ADMIN_PASSWORD" ]; then
    die "ADMIN_PASSWORD is set but empty. Set it to the password you want, or leave it unset to keep the current login."
  fi
  if [[ "$ADMIN_PASSWORD" == *[[:cntrl:]]* ]]; then
    die "ADMIN_PASSWORD can't contain a control character, such as a tab or a newline."
  fi
  if [ "${#ADMIN_PASSWORD}" -gt 128 ]; then
    die "ADMIN_PASSWORD is longer than 128 characters."
  fi
  read_stored_login
  if [ "$STORED_UNUSABLE" = 1 ] && [ -z "$ADMIN_PASSWORD_SET" ]; then
    die "the stored admin login can't be used (its user name has characters other than letters, digits and . _ @ + -, or it can't be read). Pass ADMIN_USER and ADMIN_PASSWORD to set it again. Nothing was changed."
  fi
  if [ -z "$ADMIN_USER_GIVEN" ]; then ADMIN_USER=${STORED_USER:-admin}; fi
  valid_admin_user "$ADMIN_USER" \
    || die "ADMIN_USER can only have letters, digits and . _ @ + - (the Caddyfile and the browser's login can't carry other characters)."
}

# admin_login_hash: the login's hash for the Caddyfile, as ADMIN_ALGO, ADMIN_HASH and ADMIN_FP, and ADMIN_LOGIN for the
# banner (given, kept or default). Runs after check_admin_login.
#  - ADMIN_PASSWORD passed: the stored hash when it's argon2id and made from this password, so the Caddyfile doesn't
#    change; otherwise a new argon2id hash. Caddy reads the password on stdin, so it's never in a command line, and
#    argon2id has no length limit (bcrypt stopped at 72 bytes, O9).
#  - not passed: the stored login as it is (O11). Only a first install, with nothing stored, gets changeme.
admin_login_hash(){
  local pw=$ADMIN_PASSWORD
  ADMIN_LOGIN=given
  if [ -z "$ADMIN_PASSWORD_SET" ]; then
    if [ -n "$STORED_HASH" ]; then
      ADMIN_ALGO=$STORED_ALGO ADMIN_HASH=$STORED_HASH ADMIN_FP=$STORED_FP ADMIN_LOGIN=kept
      echo "  ADMIN_PASSWORD wasn't passed: the login keeps its password."
      return 0
    fi
    pw=changeme ADMIN_LOGIN=default
  fi
  if [ "$STORED_ALGO" = argon2id ] && [ -n "$STORED_FP" ] && [ "$(login_fingerprint "$STORED_HASH" "$pw")" = "$STORED_FP" ]; then
    ADMIN_ALGO=argon2id ADMIN_HASH=$STORED_HASH ADMIN_FP=$STORED_FP
    return 0
  fi
  ADMIN_HASH=$(printf '%s\n' "$pw" | "$CADDY_BIN" hash-password --algorithm argon2id) || ADMIN_HASH=""
  [[ "$ADMIN_HASH" == '$argon2id$'* ]] \
    || die "Caddy couldn't hash ADMIN_PASSWORD with argon2id (Caddy $CADDY_VERSION). Use the default CADDY_VERSION. Nothing was changed."
  ADMIN_ALGO=argon2id
  ADMIN_FP=$(login_fingerprint "$ADMIN_HASH" "$pw")
}

write_caddyfile(){
  step "Writing Caddyfile (TLS=$TLS_MODE, AUTH=$AUTH_MODE)"
  mkdir -p "$CADDY_DIR"
  local site global_block="" tls_line="" auth_block=""

  case "$TLS_MODE" in
    none)     site=":$TCP_PORT" ;;
    internal) site="https://$MGMT_IP:$TCP_PORT https://$FQDN:$TCP_PORT"
              global_block=$'{\n  default_sni '"$MGMT_IP"$'\n}\n'
              tls_line="  tls internal" ;;
    auto)     site="$FQDN:$TCP_PORT" ;;
    *) die "invalid TLS_MODE '$TLS_MODE'" ;;
  esac

  if [ "$AUTH_MODE" = "basic" ]; then
    admin_login_hash
    # The algorithm is named, so an argon2id hash and a bcrypt one kept from before 1.2.0 both work (O9).
    auth_block="    basic_auth $ADMIN_ALGO {"$'\n'"      $ADMIN_USER $ADMIN_HASH"$'\n'"    }"
    # The login this Caddyfile holds, for the next run. Moved into place with the Caddyfile.
    ( umask 077
      printf 'user=%s\nalgorithm=%s\nhash=%s\nfingerprint=%s\n' "$ADMIN_USER" "$ADMIN_ALGO" "$ADMIN_HASH" "$ADMIN_FP" \
        > "$CADDY_DIR/admin-login.new" )
  fi

  {
    [ -n "$global_block" ] && printf '%s\n' "$global_block" || true
    echo "$site {"
    [ -n "$tls_line" ] && echo "$tls_line" || true
    cat <<EOF
  header {
    -Server
    X-Content-Type-Options nosniff
    X-Frame-Options SAMEORIGIN
    Referrer-Policy no-referrer
  }
  handle /healthz {
    reverse_proxy unix/$APP_DIR/web.sock
  }
  handle {
EOF
    [ -n "$auth_block" ] && printf '%s\n' "$auth_block" || true
    cat <<EOF
    reverse_proxy unix/$APP_DIR/web.sock
  }
}
EOF
  } > "$CADDY_DIR/Caddyfile.new"

  "$CADDY_BIN" validate --config "$CADDY_DIR/Caddyfile.new" --adapter caddyfile >/dev/null 2>&1 \
    || { rm -f "$CADDY_DIR/Caddyfile.new" "$CADDY_DIR/admin-login.new"; die "generated Caddyfile failed validation"; }
}

write_install_env(){
  cat > "$APP_DIR/.install-env" <<EOF
APP_DIR="$APP_DIR"
PERSIST_DIR="$PERSIST_DIR"
APP_USER="$APP_USER"
TCP_PORT="$TCP_PORT"
TLS_MODE="$TLS_MODE"
AUTH_MODE="$AUTH_MODE"
MGMT_IP="$MGMT_IP"
FQDN="$FQDN"
SCRIPT_VERSION="$SCRIPT_VERSION"
EOF
}

start_services(){
  step "Enabling and starting services"
  chown -R "$APP_USER:$APP_USER" "$APP_DIR"
  chown -R "$APP_USER:$APP_USER" "$PERSIST_DIR"; chmod 750 "$PERSIST_DIR"
  chmod 600 "$APP_DIR/azure.env"
  systemctl daemon-reload
  for svc in od-cameras od-web od-caddy; do
    systemctl enable "$svc" >/dev/null 2>&1
    systemctl restart "$svc"
  done
}

# validate_inputs: settings that would otherwise fail halfway through an install, after the app was stopped.
validate_inputs(){
  case "$TLS_MODE" in none|internal|auto) ;; *) die "invalid TLS_MODE '$TLS_MODE' (none | internal | auto)." ;; esac
  case "$AUTH_MODE" in none|basic) ;; *) die "invalid AUTH_MODE '$AUTH_MODE' (none | basic)." ;; esac
  case "$TCP_PORT" in ''|*[!0-9]*) die "invalid TCP_PORT '$TCP_PORT' (a port number)." ;; esac
  [ "$TCP_PORT" -ge 1 ] && [ "$TCP_PORT" -le 65535 ] || die "invalid TCP_PORT '$TCP_PORT' (1-65535)."
  # O6: auto TLS gets a certificate from a public CA, which needs a real name. The od.<hostname> fallback isn't one.
  if [ "$TLS_MODE" = "auto" ] && [ -z "$FQDN_GIVEN" ]; then
    die "TLS_MODE=auto needs FQDN set to a public DNS name that points at this host (got the fallback '$FQDN'). Set FQDN, or use TLS_MODE=internal."
  fi
  # Spec 21: the admin login and the camera logins, each refused here with its own message, before anything changes.
  check_admin_login
  check_cameras
}

# wait_healthy: the app answers /healthz on its socket within 30 s. Through the venv's Python: an air-gapped host
# may have no curl.
wait_healthy(){
  "$APP_DIR/venv/bin/python" - "$APP_DIR/web.sock" <<'PYEOF'
import socket, sys, time
deadline = time.time() + 30
while time.time() < deadline:
    try:
        s = socket.socket(socket.AF_UNIX); s.settimeout(3); s.connect(sys.argv[1])
        s.sendall(b"GET /healthz HTTP/1.0\r\nHost: localhost\r\n\r\n")
        head = s.recv(32); s.close()
        if head.startswith(b"HTTP/1.") and head.split()[1:2] == [b"200"]:
            sys.exit(0)
    except OSError:
        pass
    time.sleep(1)
sys.exit(1)
PYEOF
}

# ----------------------------------------------------------------- commands
do_install(){
  require_root
  if [ "$AZURE_VISION_KEY" = "YOUR_AZURE_KEY_HERE" ] || [ "$AZURE_VISION_ENDPOINT" = "YOUR_AZURE_ENDPOINT_HERE" ]; then
    die "set AZURE_VISION_KEY and AZURE_VISION_ENDPOINT (env vars or edit this script)."
  fi
  detect_distro
  if is_offline; then
    AIR_GAPPED_MODE=1
    OFFLINE_DIR="$(mktemp -d)"
    step "Air-gap bundle detected ($OFFLINE_SENTINEL) -> offline install"
    tar xzf "$SCRIPT_DIR/$OFFLINE_SENTINEL" -C "$OFFLINE_DIR"
    trap '[ -n "$OFFLINE_DIR" ] && rm -rf "$OFFLINE_DIR"' EXIT
  fi
  validate_inputs
  # Everything that can fail runs first, while a running app keeps running. Its files and config change only after
  # it has stopped.
  install_os_packages
  install_caddy
  create_user_dirs
  setup_venv
  write_caddyfile
  # Each of these writes its file to a .new and moves it into place only when it worked, so a bad value or a damaged
  # file stops the run here, with the running app untouched.
  write_cameras_json
  write_config_json
  for svc in od-caddy od-web od-cameras; do systemctl stop "$svc" 2>/dev/null || true; done
  copy_app_files
  write_azure_env
  write_systemd
  mv -f "$CADDY_DIR/Caddyfile.new" "$CADDY_DIR/Caddyfile"
  if [ -f "$CADDY_DIR/admin-login.new" ]; then mv -f "$CADDY_DIR/admin-login.new" "$CADDY_DIR/admin-login"; fi
  write_install_env
  start_services
  step "Checking the app answers"
  wait_healthy || die "the app didn't answer /healthz within 30 s. Check: journalctl -u od-web -u od-cameras -u od-caddy"
  echo "  healthy"
  echo
  echo "============================================================"
  echo " Object Detector Web v$SCRIPT_VERSION deployed."
  local scheme="http"; [ "$TLS_MODE" != "none" ] && scheme="https" || true
  echo "   URL:   $scheme://$MGMT_IP:$TCP_PORT/"
  if [ "$AUTH_MODE" = "basic" ]; then
    case "$ADMIN_LOGIN" in
      kept)    echo "   Login: $ADMIN_USER / (the password set before: ADMIN_PASSWORD wasn't passed, so it's unchanged)" ;;
      default) echo "   Login: $ADMIN_USER / changeme (the default: set ADMIN_PASSWORD to change it)" ;;
      *)       echo "   Login: $ADMIN_USER / (your ADMIN_PASSWORD)" ;;
    esac
  fi
  [ "$TLS_MODE" = "internal" ] && echo "   (TLS is self-signed - expect a one-time browser warning)" || true
  # From state/config.json, which is what the app uses.
  echo "   Azure: $(config_value azure api_version)  |  budget $(config_value azure monthly_budget) tx/mo ($(config_value azure budget_mode))"
  echo "============================================================"
}

ensure_save_tools(){
  case "$PKG" in
    apt)    apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y python3-venv python3-pip curl tar dpkg-dev >/dev/null ;;
    dnf)    dnf install -y python3 python3-pip curl tar dnf-plugins-core createrepo_c >/dev/null 2>&1 || true ;;
    zypper) zypper --non-interactive install python3 python3-pip curl tar createrepo_c >/dev/null 2>&1 || true ;;
  esac
}

# Write a LICENSES/ dir into the air-gap bundle ($1 = stage dir): a third-party manifest
# plus a GPL/LGPL written offer for the bundled OS-distribution packages (notably ffmpeg,
# which on Debian/Ubuntu is a GPL build). Source for distro packages is available from the
# OS distribution's own source archives; the offer is the portable backstop.
generate_bundle_licenses(){
  local dir="$1/LICENSES" pkgs="${2:-$(os_pkg_list)}" ffmpeg_line="" ffmpeg_offer=""
  mkdir -p "$dir"
  case " $pkgs " in
    *" ffmpeg "*)
      ffmpeg_line="  ffmpeg ................................. GPL-2.0+ (Debian/Ubuntu --enable-gpl build); see WRITTEN_OFFER.txt"
      ffmpeg_offer="ffmpeg (built under the GNU General Public License on Debian/Ubuntu) and " ;;
  esac
  cat > "$dir/THIRD_PARTY_NOTICES.txt" <<EOF
Third-party components redistributed in this object_detector_web air-gap bundle
Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)

Caddy ${CADDY_VERSION} binary ............ Apache-2.0   https://github.com/caddyserver/caddy
Python wheels: Flask (BSD-3), Gunicorn (MIT), gevent (MIT), OpenCV (Apache-2.0),
  NumPy (BSD-3), Azure AI Vision SDKs (MIT) .. see each wheel's own metadata
OS packages [$pkgs]:
${ffmpeg_line:+$ffmpeg_line
}  libglib2.0-0 .......................... LGPL-2.1+
  others (python3-venv/pip, libgl1) ..... permissive

The Azure AI Vision service is proprietary Microsoft (called with your key; not
redistributed). The installer and app are Apache-2.0 (Chubtoad5).
EOF
  cat > "$dir/WRITTEN_OFFER.txt" <<EOF
WRITTEN OFFER FOR CORRESPONDING SOURCE CODE (GPL / LGPL)

This air-gap bundle redistributes operating-system distribution packages, including
${ffmpeg_offer}glib (LGPL).

The corresponding source for these distribution packages is available from the OS
distribution's own source archives (e.g. 'apt-get source <package>', or the
distribution's source mirrors for the exact version bundled). In accordance with GPLv2
section 3 / GPLv3 section 6, the distributor of this bundle additionally offers, valid
for three (3) years from the date this bundle was created ($(date -u +%Y-%m-%d)), to
provide the corresponding source for these packages on a physical medium for no more
than the cost of distribution.

To request the source, contact: ${LICENSE_OFFER_CONTACT}

This offer is independent of the Apache-2.0 license covering the installer and app.
EOF
  echo "  Wrote LICENSES/ (manifest + GPL/LGPL written offer for bundled OS packages)."
}

do_save(){
  require_root
  detect_distro
  [ -d "$SCRIPT_DIR/app" ] || die "app/ directory not found next to deploy.sh"
  step "Building air-gap bundle ($OFFLINE_SENTINEL) for ${OS_ID} / $(caddy_arch) / python$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null)"
  ensure_save_tools
  local stage; stage="$(mktemp -d)"

  step "Saving OS packages via install-packages"
  if [ -f "$SCRIPT_DIR/install_packages.sh" ]; then
    cp "$SCRIPT_DIR/install_packages.sh" "$stage/"
  else
    curl -fsSL "$INSTALL_PKGS_URL" -o "$stage/install_packages.sh" || die "could not fetch install_packages.sh"
  fi
  chmod +x "$stage/install_packages.sh"
  local pkgs; pkgs=$(save_pkg_list)
  # shellcheck disable=SC2086 # one word per package
  ( cd "$stage" && ./install_packages.sh save $pkgs ) || die "OS package save failed"

  step "Downloading Python wheels"
  python3 -m venv "$stage/.dlvenv"
  "$stage/.dlvenv/bin/pip" install --upgrade pip >/dev/null
  "$stage/.dlvenv/bin/pip" download -r "$SCRIPT_DIR/app/requirements.txt" -d "$stage/wheels" >/dev/null || die "pip download failed"
  rm -rf "$stage/.dlvenv"

  step "Bundling Caddy ${CADDY_VERSION} binary"
  local tmp; tmp="$(mktemp -d)"
  curl -fsSL "$(caddy_url)" -o "$tmp/caddy.tar.gz" || die "Caddy download failed"
  tar xzf "$tmp/caddy.tar.gz" -C "$stage" caddy
  rm -rf "$tmp"

  cat > "$stage/save-manifest.txt" <<EOF
object_detector_web air-gap bundle
created: $(date -u +%Y-%m-%dT%H:%M:%SZ)
os: ${OS_ID} ${VERSION_ID:-}
arch: $(caddy_arch)
python: $(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])')
caddy: ${CADDY_VERSION}
os_packages: $pkgs
EOF

  generate_bundle_licenses "$stage" "$pkgs"

  step "Packing $OFFLINE_SENTINEL"
  tar czf "$SCRIPT_DIR/$OFFLINE_SENTINEL" -C "$stage" .
  rm -rf "$stage"
  echo
  echo "============================================================"
  echo " Air-gap bundle ready: $SCRIPT_DIR/$OFFLINE_SENTINEL"
  echo "   Size: $(du -h "$SCRIPT_DIR/$OFFLINE_SENTINEL" | cut -f1)"
  echo "   NOTE: bundle is specific to ${OS_ID} ${VERSION_ID:-} / $(caddy_arch) / python$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])')."
  echo "   Transfer this whole repo dir (deploy.sh + app/ + camera_unavailable.jpg)"
  echo "   AND $OFFLINE_SENTINEL to the air-gapped host, then run:"
  echo "     sudo AZURE_VISION_KEY=... AZURE_VISION_ENDPOINT=... ./deploy.sh install"
  echo "   (the bundle is auto-detected and used; no internet required)"
  echo "============================================================"
}

do_uninstall(){
  require_root
  [ -f "$APP_DIR/.install-env" ] && . "$APP_DIR/.install-env" || true
  step "Uninstalling Object Detector Web"
  for svc in od-caddy od-web od-cameras; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    rm -f "/etc/systemd/system/$svc.service"
  done
  systemctl daemon-reload
  rm -f "$CADDY_DIR/Caddyfile" "$CADDY_DIR/Caddyfile.new" "$CADDY_DIR/admin-login" "$CADDY_DIR/admin-login.new"
  rmdir "$CADDY_DIR" 2>/dev/null || true
  rm -f /usr/local/bin/caddy
  # clear any shared-memory frame buffers
  rm -f /dev/shm/od_frame_* 2>/dev/null || true
  if [ "${PURGE,,}" = "true" ]; then
    rm -rf "$APP_DIR" "$PERSIST_DIR"
    echo "  purged $APP_DIR + $PERSIST_DIR (snapshots + state + budget removed)"
  else
    rm -rf "$APP_DIR/venv" "$APP_DIR"/*.py "$APP_DIR/templates" "$APP_DIR/azure.env" \
           "$APP_DIR/cameras.json" "$APP_DIR/cameras.json.new" "$APP_DIR/.install-env" "$APP_DIR/requirements.txt" "$APP_DIR/web.sock"
    echo "  removed app (kept $APP_DIR/state + snapshots + $PERSIST_DIR/budget.json; set PURGE=true to delete)"
  fi
  id "$APP_USER" >/dev/null 2>&1 && { userdel "$APP_USER" 2>/dev/null || true; echo "  removed user $APP_USER"; }
  echo "  uninstall complete"
}

do_status(){
  [ -f "$APP_DIR/.install-env" ] && . "$APP_DIR/.install-env" || true
  echo "Object Detector Web - status"
  for svc in od-cameras od-web od-caddy; do
    printf "  %-12s %s\n" "$svc" "$(systemctl is-active "$svc" 2>/dev/null || echo absent)"
  done
  if [ -f "$PERSIST_DIR/budget.json" ]; then
    echo "  budget:      $(cat "$PERSIST_DIR/budget.json")"
  fi
  local scheme="http"; [ "${TLS_MODE:-internal}" != "none" ] && scheme="https" || true
  local host="${MGMT_IP:-$(hostname -I|awk '{print $1}')}"
  echo "  URL:         $scheme://$host:${TCP_PORT:-443}/"
  if command -v curl >/dev/null 2>&1; then
    echo "  healthz:     $(curl -sk "$scheme://$host:${TCP_PORT:-443}/healthz" 2>/dev/null || echo unreachable)"
  fi
}

usage(){
  cat <<EOF
Object Detector Web v$SCRIPT_VERSION

Usage: sudo [VAR=value ...] ./deploy.sh [command]

Commands:
  install     Deploy/refresh the app (default). Auto-detects an air-gap bundle
              ($OFFLINE_SENTINEL) next to this script and installs offline.
  save        Build an air-gap bundle ($OFFLINE_SENTINEL): OS packages (via
              install-packages), Python wheels, and the Caddy binary.
  uninstall   Stop and remove the app (PURGE=true also deletes state/snapshots)
  status      Show service + health status
  version     Print version
  help        This help

Key variables (see README for the full table):
  AZURE_VISION_KEY, AZURE_VISION_ENDPOINT   (required)
  AZURE_API_VERSION=v4|v3.2   AZURE_MONTHLY_BUDGET=4500   AZURE_BUDGET_MODE=soft|hard
  RTSP_URL=...  RTSP_USER  RTSP_PASSWORD   (the login is percent-encoded into the URL for you)
  CAMERA_1_URL=... CAMERA_1_USER CAMERA_1_PASSWORD CAMERA_1_NAME=...   ENABLE_USB=true   CAMERAS_RESET=true
  USB_KERNEL_TRACK=true|false  (ENABLE_USB: keep uvcvideo across kernel upgrades; default true)
  TLS_MODE=none|internal|auto   AUTH_MODE=none|basic   ADMIN_USER  ADMIN_PASSWORD   TCP_PORT
    (a re-run without ADMIN_PASSWORD keeps the login; a first install without it gets admin / changeme)
  FEATURE_TAGS/OBJECTS/CAPTION/PEOPLE/DENSE/OCR/BRANDS/COLOR=true|false
  DRAW_BOXES  CONFIDENCE  AUTO_ANALYZE  AUTO_INTERVAL  KEYWORD_WATCH  KEYWORD_TERMS
EOF
}

# ----------------------------------------------------------------- dispatch
# When sourced by a test harness, stop here: only the functions above are wanted.
if [[ "${BASH_SOURCE[0]:-$0}" != "$0" ]]; then
  return 0
fi

CMD="${1:-install}"
case "$CMD" in
  install)   do_install ;;
  save)      do_save ;;
  uninstall) do_uninstall ;;
  status)    do_status ;;
  version|--version|-v) echo "$SCRIPT_VERSION" ;;
  help|-h|--help) usage ;;
  *) echo "Unknown command: $CMD" >&2; usage; exit 1 ;;
esac
