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
BOLD='\033[1m'
UNDERLINE='\033[4m'
REVERSE='\033[7m'
NC='\033[0m' # No colour

die() { printf "${YELLOW}ERROR:${NC} %s\n" "$1" >&2; exit 1; }
info() { printf "${BLUE}→${NC} %s\n" "$1"; }
ok()   { printf "${GREEN}✔ %s${NC}\n" "$1"; }
warn() { printf "${YELLOW}⚠ %s${NC}\n" "$1"; }
outstanding() { printf "${BOLD}${YELLOW}‼ %s${NC}\n" "$1"; }
poster() { printf "${REVERSE}${YELLOW}✔ %s${NC}\n" "$1" >&2; }

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
# --- Detect Raspberry Pi LAN IP ---
info "Detecting Raspberry Pi LAN IP address..."

# Try to get the first non-loopback IPv4 address
PI_IP=$(hostname -I | awk '{print $1}')

if [[ -z "$PI_IP" ]]; then
  warn "Could not automatically detect LAN IP — defaulting to 127.0.0.1"
  PI_IP="127.0.0.1"
else
  poster "Detected LAN IP: $PI_IP"
fi

# Display to user and confirm
whiptail --title "Raspberry Pi IP Detected" \
  --yesno "Your Raspberry Pi appears to have the IP:\n\n  $PI_IP\n\nUse this as the streaming host for Darkice and Icecast2?" \
  15 60

if [[ $? -ne 0 ]]; then
  CUSTOM_IP=$(whiptail --inputbox "Enter the IP or hostname to use for Darkice/Icecast2:" 10 60 "$PI_IP" 3>&1 1>&2 2>&3)
  if [[ -n "$CUSTOM_IP" ]]; then
    PI_IP="$CUSTOM_IP"
  fi
fi

poster "Streaming host will use: $PI_IP"

STREAM_URL=$(whiptail --inputbox \
  "Enter your public stream URL  as http://"$PI_IP":8000/stream - This is for your Live Stream." \
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
ICECAST_WEB_DIR="/usr/share/icecast2/web"

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
outstanding "Darkice files copied successfully."

# --- DEBUG: verify copied config and variables before substitutions ---
echo "DEBUG: DEST_DARKICE_CFG = '$DEST_DARKICE_CFG'"
if [[ -f "$DEST_DARKICE_CFG" ]]; then
    echo "DEBUG: File exists: $(ls -l "$DEST_DARKICE_CFG")"
else
    warn "DEBUG: $DEST_DARKICE_CFG does not exist!"
fi
echo "DEBUG: STREAM_URL = '$STREAM_URL'"
echo -e "Use ${YELLOW}${REVERSE} ${PI_IP}${NC} for your host in Icecast2 configuration."

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
    if [[ -f "$DEST_DARKICE_CFG" ]]; then
        sed -i -r "s/(password *= *)source/\1$ESCAPED_PASS/" "$DEST_DARKICE_CFG"
        ok "Replaced placeholder password = source with actual Icecast source password."
    else
        warn "${YELLOW}$DEST_DARKICE_CFG missing; cannot replace password.${NC}"
    fi
  else
    warn "Could not extract <source-password>; edit /etc/darkice.cfg manually."
  fi
else
  warn "No /etc/icecast2/icecast.xml found — cannot extract password."
fi

# --- Replace 'your_domain' with provided public URL in darkice.cfg ---
# Ensure the darkice.cfg exists
if [[ -f "$DEST_DARKICE_CFG" && -n "$STREAM_URL" ]]; then
    info "Replacing 'your_domain' in darkice.cfg with user-provided URL..."

    # escape any characters that might confuse sed
    ESCAPED_URL=$(printf '%s\n' "$STREAM_URL" | sed -e 's/[\/&]/\\&/g')

    # Replace exactly 'your_domain' after 'url =' (allow spaces and optional quotes)
    sed -i -E 's#^[[:space:]]*url[[:space:]]*=[[:space:]]*"?your_domain"?#url='"$ESCAPED_URL"'#' "$DEST_DARKICE_CFG"

    ok "darkice.cfg updated: url = $STREAM_URL"
    #sed -i "s/^server[[:space:]]*=[[:space:]]*localhost/server = $PI_IP/" "$DEST_DARKICE_CFG"
    #poster "Updated server address in darkice.cfg to $PI_IP."
else
    warn "darkice.cfg not found or no URL provided; skipping URL substitution."
fi


# # --- Extract CALLSIGN from svxlink.conf ---
if [[ -f "$SVXLINK_CONF" ]]; then
    CALLSIGN=$(grep -m1 '^[[:space:]]*CALLSIGN[[:space:]]*=' "$SVXLINK_CONF" \
               | sed -E 's/^[[:space:]]*CALLSIGN[[:space:]]*=[[:space:]]*//')
    info "DEBUG: CALLSIGN extracted = '$CALLSIGN'"
else
    warn "$SVXLINK_CONF not found; cannot extract CALLSIGN"
fi

# --- Replace 'callsign' in darkice.cfg ---
if [[ -n "$CALLSIGN" && -f "$DEST_DARKICE_CFG" ]]; then
    sed -i "s/callsign/$CALLSIGN/g" "$DEST_DARKICE_CFG"
    ok "Replaced 'callsign' placeholder with CALLSIGN '$CALLSIGN' in darkice.cfg."
else
    warn "CALLSIGN not set or darkice.cfg missing; skipping substitution."
fi



# --- TX=Tx1 → TX=MultiTx in svxlink.conf ---
if [[ -f "$SVXLINK_CONF" ]]; then
    info "Replacing TX=Tx1 → TX=MultiTx in svxlink.conf logic sections..."

    # SimplexLogic
    if grep -q '^\[SimplexLogic\]' "$SVXLINK_CONF"; then
        sed -i '/^\[SimplexLogic\]/,/^\[/ { s/^[[:space:]]*TX[[:space:]]*=[[:space:]]*Tx1/TX=MultiTx/ }' "$SVXLINK_CONF"
        ok "[SimplexLogic] updated to TX=MultiTx if TX=Tx1 existed"
    else
        warn "[SimplexLogic] section not found; skipping"
    fi

    # RepeaterLogic
    if grep -q '^\[RepeaterLogic\]' "$SVXLINK_CONF"; then
        sed -i '/^\[RepeaterLogic\]/,/^\[/ { s/^[[:space:]]*TX[[:space:]]*=[[:space:]]*Tx1/TX=MultiTx/ }' "$SVXLINK_CONF"
        ok "[RepeaterLogic] updated to TX=MultiTx if TX=Tx1 existed"
    else
        warn "[RepeaterLogic] section not found; skipping"
    fi
else
    warn "svxlink.conf missing; cannot modify TX"
fi

# --- Replace 'callsign' placeholder in darkice.cfg ---
if [[ -n "$CALLSIGN" && -f "$DEST_DARKICE_CFG" ]]; then
    sed -i "s/callsign/$CALLSIGN/g" "$DEST_DARKICE_CFG"
    ok "Replaced 'callsign' placeholder with CALLSIGN '$CALLSIGN' in darkice.cfg."
else
    warn "CALLSIGN not set or darkice.cfg missing; skipping substitution."
fi


if [[ -n "$CALLSIGN" && -d "$ICECAST_WEB_DIR" ]]; then
    info "Customizing Icecast web interface (.xsl files only) with CALLSIGN '$CALLSIGN'..."
    
    BACKUP_DIR="${ICECAST_WEB_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
    cp -r "$ICECAST_WEB_DIR" "$BACKUP_DIR"
    ok "Backup of Icecast web files saved to $BACKUP_DIR"

    # Process all .xsl files
    find -L "$ICECAST_WEB_DIR" -type f -iname "*.xsl" | while read -r file; do
        if grep -q "Icecast2" "$file"; then
            echo "Found 'Icecast2' in $file"
            sed -i "s/Icecast2/$CALLSIGN/g" "$file"
            echo "Replaced 'Icecast2' with '$CALLSIGN' in $file"
        else
            echo "No 'Icecast2' found in $file; skipping"
        fi
    done

    ok "All .xsl files processed with CALLSIGN '$CALLSIGN'."
else
    warn "CALLSIGN not set or Icecast web directory missing; skipping .xsl customization."
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
info "Restarting with a health check"
# --- Post-restart sanity check for Darkice + Icecast2 ---
info "Performing sanity check on stream URL..."

# Restart services to ensure fresh start
systemctl restart icecast2.service darkice.service

# Wait a few seconds for services to come online
sleep 5

# Check if Icecast web UI responds
STREAM_CHECK_URL="http://$PI_IP:8000/"
if curl -s --head "$STREAM_CHECK_URL" | head -n 1 | grep "200\|302" >/dev/null; then
    ok "Stream web UI reachable at $STREAM_CHECK_URL — Darkice + Icecast2 appear operational."
else
    warn "Stream web UI NOT reachable at $STREAM_CHECK_URL — manual check may be required."
fi

echo
info "NOTES:"
echo " - If [TxStream] was missing, configure svxlink manually."
echo " - Verify /etc/darkice.cfg for correct Icecast password and mountpoint."
echo " - Access Icecast2 at http://<yourpi>:8000/"
echo " - Check services with:"
echo "     sudo systemctl status darkice.service"
echo "     sudo systemctl status icecast2.service"
echo
[[ -n "$STREAM_URL" ]] && info "Public stream URL: $STREAM_URL${NC}"
echo 
outstanding "A reboot is not necessary"
echo
info "Log file: $LOG_FILE"
echo -e "\n=== Setup complete: $(date) ===\n"

exit 0
