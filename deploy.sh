#!/bin/bash
# =============================================================================
# Object Detector Web - all-in-one installer
#   Containerless: Caddy (binary) + Python venv + systemd.
#   Commands: install (default) | uninstall | status | version | help
#   All variables below are runtime-overridable:  sudo VAR=value ./deploy.sh
# =============================================================================
set -e
SCRIPT_VERSION="1.0.3"

# ----------------------------------------------------------------- config
# --- Azure Computer Vision (Image Analysis) ---
AZURE_VISION_KEY="${AZURE_VISION_KEY:-YOUR_AZURE_KEY_HERE}"
AZURE_VISION_ENDPOINT="${AZURE_VISION_ENDPOINT:-YOUR_AZURE_ENDPOINT_HERE}"
AZURE_API_VERSION="${AZURE_API_VERSION:-v4}"            # v4 | v3.2
AZURE_MONTHLY_BUDGET="${AZURE_MONTHLY_BUDGET:-4500}"    # free F0 cap is 5000 tx/mo
AZURE_BUDGET_MODE="${AZURE_BUDGET_MODE:-soft}"          # soft (warn) | hard (block)

# --- Cameras (RTSP_URL = convenience single cam; or CAMERA_1_URL .. CAMERA_8_URL) ---
RTSP_URL="${RTSP_URL:-}"
ENABLE_USB="${ENABLE_USB:-false}"                       # true => add a /dev/video0 local camera
USB_KERNEL_TRACK="${USB_KERNEL_TRACK:-true}"            # ENABLE_USB only: keep uvcvideo across kernel upgrades

# --- Web / TLS / auth ---
TLS_MODE="${TLS_MODE:-internal}"                        # none | internal (self-signed) | auto (LE)
AUTH_MODE="${AUTH_MODE:-basic}"                         # none | basic
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-changeme}"
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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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
    ( cd "$OFFLINE_DIR" && ./install_packages.sh offline $(os_pkg_list) )
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
  cp "$SCRIPT_DIR/app/analyzer.py" "$SCRIPT_DIR/app/camera_supervisor.py" "$SCRIPT_DIR/app/app.py" "$APP_DIR/"
  cp "$SCRIPT_DIR/app/requirements.txt" "$APP_DIR/"
  cp "$SCRIPT_DIR/app/templates/index.html" "$APP_DIR/templates/"
  if [ -f "$SCRIPT_DIR/camera_unavailable.jpg" ]; then
    cp "$SCRIPT_DIR/camera_unavailable.jpg" "$APP_DIR/static/"
  else
    echo "  WARNING: camera_unavailable.jpg not found; placeholder will be blank."
  fi
}

write_cameras_json(){
  step "Writing cameras.json"
  export RTSP_URL ENABLE_USB
  for i in 1 2 3 4 5 6 7 8; do export "CAMERA_${i}_URL" "CAMERA_${i}_NAME" "CAMERA_${i}_TYPE" "CAMERA_${i}_DEVICE" 2>/dev/null || true; done
  python3 - <<'PYEOF' > "$APP_DIR/cameras.json"
import os, json
cams=[]
def add(cid,name,ctype,url=None,device=None,enabled=True):
    c={"id":cid,"name":name,"type":ctype,"enabled":enabled}
    if url: c["url"]=url
    if device: c["device"]=device
    cams.append(c)
explicit=False
for i in range(1,9):
    u=os.environ.get("CAMERA_%d_URL"%i,"").strip()
    if u:
        explicit=True
        add("cam%d"%i, os.environ.get("CAMERA_%d_NAME"%i,"Camera %d"%i),
            os.environ.get("CAMERA_%d_TYPE"%i,"rtsp"), url=u,
            device=os.environ.get("CAMERA_%d_DEVICE"%i))
rtsp=os.environ.get("RTSP_URL","").strip()
if rtsp and not explicit and not rtsp.startswith("rtsp://192.168.1.250"):
    add("cam1","RTSP Camera","rtsp",url=rtsp)
if os.environ.get("ENABLE_USB","false").lower()=="true":
    add("usb0","USB Camera","local",device="/dev/video0")
print(json.dumps({"cameras":cams}, indent=2))
PYEOF
  echo "  $(python3 -c 'import json;print(len(json.load(open("'"$APP_DIR"'/cameras.json"))["cameras"]))') camera(s) configured"
}

write_config_json(){
  if [ -f "$APP_DIR/state/config.json" ]; then
    echo "  preserving existing runtime config (state/config.json)"
    return
  fi
  step "Writing default runtime config"
  export FEATURE_TAGS FEATURE_OBJECTS FEATURE_CAPTION FEATURE_PEOPLE FEATURE_DENSE \
         FEATURE_OCR FEATURE_BRANDS FEATURE_COLOR DRAW_BOXES CONFIDENCE AUTO_ANALYZE \
         AUTO_INTERVAL KEYWORD_WATCH KEYWORD_TERMS KEYWORD_SOUND KEYWORD_NOTIFY \
         SNAPSHOTS SNAPSHOTS_ON_DETECTION AZURE_API_VERSION AZURE_MONTHLY_BUDGET AZURE_BUDGET_MODE
  python3 - <<'PYEOF' > "$APP_DIR/state/config.json"
import os, json
b=lambda k,d: os.environ.get(k, "true" if d else "false").lower()=="true"
terms=[t.strip() for t in os.environ.get("KEYWORD_TERMS","").split(",") if t.strip()]
cfg={
 "features":{"tags":b("FEATURE_TAGS",1),"objects":b("FEATURE_OBJECTS",1),
   "caption":b("FEATURE_CAPTION",1),"people":b("FEATURE_PEOPLE",0),
   "dense":b("FEATURE_DENSE",0),"ocr":b("FEATURE_OCR",0),
   "brands":b("FEATURE_BRANDS",0),"color":b("FEATURE_COLOR",0)},
 "draw_boxes":b("DRAW_BOXES",1),
 "confidence":float(os.environ.get("CONFIDENCE","0.5")),
 "auto":{"enabled":b("AUTO_ANALYZE",0),"interval":int(os.environ.get("AUTO_INTERVAL","300"))},
 "keyword":{"enabled":b("KEYWORD_WATCH",0),"terms":terms,
   "sound":b("KEYWORD_SOUND",1),"notify":b("KEYWORD_NOTIFY",0)},
 "snapshots":{"enabled":b("SNAPSHOTS",0),"on_detection":b("SNAPSHOTS_ON_DETECTION",0)},
 "ocr_panel":True,
 "events":{"enabled":True,"max":100},
 "azure":{"api_version":os.environ.get("AZURE_API_VERSION","v4"),
   "monthly_budget":int(os.environ.get("AZURE_MONTHLY_BUDGET","4500")),
   "budget_mode":os.environ.get("AZURE_BUDGET_MODE","soft")},
}
print(json.dumps(cfg, indent=2))
PYEOF
}

write_azure_env(){
  step "Writing Azure credentials (mode 600)"
  cat > "$APP_DIR/azure.env" <<EOF
AZURE_VISION_KEY=$AZURE_VISION_KEY
AZURE_VISION_ENDPOINT=$AZURE_VISION_ENDPOINT
EOF
  chmod 600 "$APP_DIR/azure.env"
}

setup_venv(){
  step "Setting up Python virtualenv"
  [ -d "$APP_DIR/venv" ] || python3 -m venv "$APP_DIR/venv"
  if [ "$AIR_GAPPED_MODE" -eq 1 ]; then
    [ -d "$OFFLINE_DIR/wheels" ] || die "offline bundle is missing Python wheels."
    "$APP_DIR/venv/bin/pip" install --no-index --find-links "$OFFLINE_DIR/wheels" -r "$APP_DIR/requirements.txt" >/dev/null
  else
    "$APP_DIR/venv/bin/pip" install --upgrade pip >/dev/null
    "$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt" >/dev/null
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

write_caddyfile(){
  step "Writing Caddyfile (TLS=$TLS_MODE, AUTH=$AUTH_MODE)"
  mkdir -p /etc/caddy
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
    local hash; hash="$(/usr/local/bin/caddy hash-password --plaintext "$ADMIN_PASSWORD")"
    auth_block=$'    basic_auth {\n      '"$ADMIN_USER $hash"$'\n    }'
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
  } > /etc/caddy/Caddyfile

  /usr/local/bin/caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 \
    || die "generated Caddyfile failed validation"
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
  # stop existing (idempotent reinstall)
  for svc in od-caddy od-web od-cameras; do systemctl stop "$svc" 2>/dev/null || true; done
  install_os_packages
  install_caddy
  create_user_dirs
  copy_app_files
  write_cameras_json
  write_config_json
  write_azure_env
  setup_venv
  write_systemd
  write_caddyfile
  write_install_env
  start_services
  echo
  echo "============================================================"
  echo " Object Detector Web v$SCRIPT_VERSION deployed."
  local scheme="http"; [ "$TLS_MODE" != "none" ] && scheme="https" || true
  echo "   URL:   $scheme://$MGMT_IP:$TCP_PORT/"
  [ "$AUTH_MODE" = "basic" ] && echo "   Login: $ADMIN_USER / (your ADMIN_PASSWORD)" || true
  [ "$TLS_MODE" = "internal" ] && echo "   (TLS is self-signed - expect a one-time browser warning)" || true
  echo "   Azure: $AZURE_API_VERSION  |  budget ${AZURE_MONTHLY_BUDGET} tx/mo ($AZURE_BUDGET_MODE)"
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
  local dir="$1/LICENSES"
  mkdir -p "$dir"
  cat > "$dir/THIRD_PARTY_NOTICES.txt" <<EOF
Third-party components redistributed in this object_detector_web air-gap bundle
Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)

Caddy ${CADDY_VERSION} binary ............ Apache-2.0   https://github.com/caddyserver/caddy
Python wheels: Flask (BSD-3), Gunicorn (MIT), gevent (MIT), OpenCV (Apache-2.0),
  NumPy (BSD-3), Azure AI Vision SDKs (MIT) .. see each wheel's own metadata
OS packages [$(os_pkg_list)]:
  ffmpeg ................................. GPL-2.0+ (Debian/Ubuntu --enable-gpl build); see WRITTEN_OFFER.txt
  libglib2.0-0 .......................... LGPL-2.1+
  others (python3-venv/pip, libgl1) ..... permissive

The Azure AI Vision service is proprietary Microsoft (called with your key; not
redistributed). The installer and app are Apache-2.0 (Chubtoad5).
EOF
  cat > "$dir/WRITTEN_OFFER.txt" <<EOF
WRITTEN OFFER FOR CORRESPONDING SOURCE CODE (GPL / LGPL)

This air-gap bundle redistributes operating-system distribution packages, including
ffmpeg (built under the GNU General Public License on Debian/Ubuntu) and glib (LGPL).

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
  ( cd "$stage" && ./install_packages.sh save $(os_pkg_list) ) || die "OS package save failed"

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
os_packages: $(os_pkg_list)
EOF

  generate_bundle_licenses "$stage"

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
  rm -f /etc/caddy/Caddyfile; rmdir /etc/caddy 2>/dev/null || true
  rm -f /usr/local/bin/caddy
  # clear any shared-memory frame buffers
  rm -f /dev/shm/od_frame_* 2>/dev/null || true
  if [ "${PURGE,,}" = "true" ]; then
    rm -rf "$APP_DIR" "$PERSIST_DIR"
    echo "  purged $APP_DIR + $PERSIST_DIR (snapshots + state + budget removed)"
  else
    rm -rf "$APP_DIR/venv" "$APP_DIR"/*.py "$APP_DIR/templates" "$APP_DIR/azure.env" \
           "$APP_DIR/cameras.json" "$APP_DIR/.install-env" "$APP_DIR/requirements.txt" "$APP_DIR/web.sock"
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
  RTSP_URL=...   CAMERA_1_URL=... CAMERA_1_NAME=...   ENABLE_USB=true
  USB_KERNEL_TRACK=true|false  (ENABLE_USB: keep uvcvideo across kernel upgrades; default true)
  TLS_MODE=none|internal|auto   AUTH_MODE=none|basic   ADMIN_USER  ADMIN_PASSWORD   TCP_PORT
  FEATURE_TAGS/OBJECTS/CAPTION/PEOPLE/DENSE/OCR/BRANDS/COLOR=true|false
  DRAW_BOXES  CONFIDENCE  AUTO_ANALYZE  AUTO_INTERVAL  KEYWORD_WATCH  KEYWORD_TERMS
EOF
}

# ----------------------------------------------------------------- dispatch
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
