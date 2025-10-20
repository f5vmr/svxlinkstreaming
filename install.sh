#!/usr/bin/env bash
# setup_svxlink_stream.sh
# Automates Darkice + Icecast2 installation and optional SvxLink configuration.
# Run as: sudo ./setup_svxlink_stream.sh

set -euo pipefail
IFS=$'\n\t'

# --- Logging setup ---
LOG_FILE="/var/log/svxlink_stream_setup.log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1
echo -e "\n=== $(date) Starting SvxLink Stream Setup ===\n"

# --- Colour definitions ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No colour

die() { printf "${RED}ERROR:${NC} %s\n" "$1" >&2; exit 1; }
info() { printf "${BLUE}→${NC} %s\n" "$1"; }
ok()   { printf "${GREEN}✔ %s${NC}\n" "$1"; }
warn() { printf "${YELLOW}⚠ %s${NC}\n" "$1"; }

[[ $EUID -ne 0 ]] && die "Please run as root (sudo)."

# --- Ensure whiptail exists ---
if ! command -v whiptail >/dev/null 2>&1; then
  info "Installing whiptail..."
  apt-get update && apt-get install -y whiptail || die "Failed to install whiptail."
fi

# --- Ask about svxlink installation ---
if whiptail --title "svxlink installation check" --yesno \
  "Have you installed svxlink using the svxlinkbuilder / svxlink image?\n\nIf NO, the script will skip svxlink checks but continue installing Darkice and Icecast2." 12 70; then
  SVXLINK_PRESENT=true
  info "User confirmed svxlink installation."
else
  SVXLINK_PRESENT=false
  warn "User has not installed svxlink via svxlinkbuilder — skipping svxlink configuration."
fi

## ----------------------------------------------------------------------
## -- Svxlink check/config section --
## ----------------------------------------------------------------------

HAS_TXSTREAM=false
SVXLINK_CONF="/etc/svxlink/svxlink.conf"

if $SVXLINK_PRESENT; then
  if [[ -f "$SVXLINK_CONF" ]]; then
    if grep -q "^\s*\[TxStream\]" "$SVXLINK_CONF"; then
      ok "Found [TxStream] in $SVXLINK_CONF — svxlink config acceptable."
      HAS_TXSTREAM=true
    else
      warn "[TxStream] not found — svxlink may be incompatible; continuing with install only."
      HAS_TXSTREAM=false
    fi
  else
    warn "$SVXLINK_CONF not found — skipping svxlink config."
  fi
fi

# --- Ask for stream URL (optional note) ---
STREAM_URL=$(whiptail --inputbox \
  "Enter your public stream URL (e.g. http://portal.svxlink.uk:8010/stream)\nThis is for your records only." \
  12 80 "" --title "Public stream URL" 3>&1 1>&2 2>&3) || true
STREAM_URL=${STREAM_URL:-""}
[[ -n "$STREAM_URL" ]] && ok "Stream URL noted: $STREAM_URL" || warn "No public stream URL provided."

## ----------------------------------------------------------------------
## -- Install section (Darkice & Icecast2) --
## ----------------------------------------------------------------------

info "Starting Darkice + Icecast2 installation..."

CWD="$(pwd)"
SRC_DIR="$CWD/svxlinkstreaming"
DEST_DARKICE_CFG="/etc/darkice.cfg"
DEST_DARKICE_SERVICE="/etc/systemd/system/darkice.service"
DEST_SCRIPT="/home/pi/scripts/darkice.sh"

# Validate source files
[[ -f "$SRC_DIR/darkice.cfg" ]] || die "Missing $SRC_DIR/darkice.cfg"
[[ -f "$SRC_DIR/darkice.service" ]] || die "Missing $SRC_DIR/darkice.service"
[[ -f "$SRC_DIR/darkice.sh" ]] || die "Missing $SRC_DIR/darkice.sh"

# Ensure /home/pi/scripts exists
if [[ ! -d "/home/pi/scripts" ]]; then
  info "Creating /home/pi/scripts..."
  mkdir -p /home/pi/scripts
  chown pi:pi /home/pi/scripts || true
fi

# Copy configuration and service files
info "Copying configuration and service files..."
cp -f "$SRC_DIR/darkice.cfg" "$DEST_DARKICE_CFG"
cp -f "$SRC_DIR/darkice.service" "$DEST_DARKICE_SERVICE"
cp -f "$SRC_DIR/darkice.sh" "$DEST_SCRIPT"
chmod +x "$DEST_SCRIPT"
chown pi:pi "$DEST_SCRIPT" || true
ok "Darkice files copied successfully."

# --- Install Darkice + Icecast2 ---
info "Installing Darkice and Icecast2 (interactive password setup follows)..."
apt-get update
DEBIAN_FRONTEND=readline apt-get install -y darkice icecast2 || die "Failed to install Darkice/Icecast2"
ok "Installation complete."

# --- Enable Icecast2 ---
ICECAST_DEFAULT="/etc/default/icecast2"
if [[ -f "$ICECAST_DEFAULT" ]]; then
  sed -i 's/^\s*ENABLE=.*/ENABLE=true/' "$ICECAST_DEFAULT" || echo "ENABLE=true" >> "$ICECAST_DEFAULT"
else
  echo "ENABLE=true" > "$ICECAST_DEFAULT"
fi
ok "Enabled Icecast2 in /etc/default/icecast2"

# --- Extract Icecast source password ---
ICECAST_XML="/etc/icecast2/icecast.xml"
if [[ -f "$ICECAST_XML" ]]; then
  ICECAST_SOURCE_PASSWORD=$(grep -oP "(?<=<source-password>).*?(?=</source-password>)" "$ICECAST_XML" | head -n1 || true)
  if [[ -n "$ICECAST_SOURCE_PASSWORD" ]]; then
    ESCAPED_PASS=$(printf '%s\n' "$ICECAST_SOURCE_PASSWORD" | sed -e 's/[\/&]/\\&/g')
    sed -i -r "s/(password *= *)source/\1$ESCAPED_PASS/" "$DEST_DARKICE_CFG" || true
    ok "Replaced placeholder password = source with actual Icecast source password."
  else
    warn "Could not extract <source-password>; edit /etc/darkice.cfg manually."
  fi
else
  warn "No /etc/icecast2/icecast.xml found — cannot extract password."
fi
# --- Replace 'your_domain' with provided public URL in darkice.cfg ---
if [[ -n "$STREAM_URL" ]]; then
  # Strip protocol prefix (http:// or https://) and port (if any) for darkice
  CLEAN_DOMAIN=$(echo "$STREAM_URL" | sed -E 's#https?://##; s#/.*##')
  if grep -q "your_domain" "$DEST_DARKICE_CFG"; then
    sed -i "s/your_domain/$CLEAN_DOMAIN/" "$DEST_DARKICE_CFG"
    ok "Replaced 'your_domain' with '$CLEAN_DOMAIN' in darkice.cfg."
  else
    warn "No 'your_domain' placeholder found in $DEST_DARKICE_CFG; skipping domain substitution."
  fi
else
  warn "No stream URL provided; 'your_domain' left unchanged in darkice.cfg."
fi

# --- Modify svxlink.conf only if TxStream found ---
if $HAS_TXSTREAM; then
  info "Updating TX=Tx1 → TX=MultiTx in [Tx1] section..."
  TMPFILE=$(mktemp)
  awk '
    BEGIN {in_tx1=0}
    /^\[Tx1\]/ {print; in_tx1=1; next}
    /^\[.*\]/ {if(in_tx1){in_tx1=0}; print; next}
    {
      if(in_tx1 && $0 ~ /^[[:space:]]*TX[[:space:]]*=[[:space:]]*Tx1/){
        sub(/TX[[:space:]]*=[[:space:]]*Tx1/, "TX=MultiTx")
      }
      print
    }' "$SVXLINK_CONF" > "$TMPFILE"
  mv "$TMPFILE" "$SVXLINK_CONF"
  ok "svxlink.conf updated for MultiTx."
else
  warn "Skipping svxlink.conf modification."
fi

# --- Enable and start services ---
systemctl daemon-reload
systemctl enable --now darkice.service icecast2.service || warn "Service enable/start issue; check logs."
ok "Services enabled and started."

# --- Add @reboot entry to root (sudo crontab) ---
CRON_ENTRY="@reboot /home/pi/scripts/darkice.sh"
if sudo crontab -l 2>/dev/null | grep -F "$CRON_ENTRY" >/dev/null 2>&1; then
  ok "Crontab entry already present in sudo crontab."
else
  (sudo crontab -l 2>/dev/null || true; echo "$CRON_ENTRY") | sudo crontab -
  ok "Added @reboot entry to sudo crontab."
fi

# --- Summary ---
echo
ok "Setup completed successfully!"
echo
info "NOTES:"
echo " - If [TxStream] was missing, configure svxlink manually."
echo " - Verify /etc/darkice.cfg for correct Icecast password and mountpoint."
echo " - Access Icecast2 at http://<yourpi>:8000/"
echo " - Check services with:"
echo "     sudo systemctl status darkice.service"
echo "     sudo systemctl status icecast2.service"
echo
[[ -n "$STREAM_URL" ]] && info "Public stream URL: $STREAM_URL"
echo
ok "A reboot is recommended to verify @reboot startup."
echo
info "Log file: $LOG_FILE"
echo -e "\n=== Setup complete: $(date) ===\n"

exit 0
