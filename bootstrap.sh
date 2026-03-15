#!/bin/bash
# DroneAware Node Bootstrap Installer
#
# Run this on a fresh Raspberry Pi OS Lite (64-bit) image to install the
# DroneAware feeder software and set up the first-boot wizard.
#
# One-liner install:
#   curl -fsSL https://droneaware.io/install | sudo bash
#
# Or if you have this file locally:
#   sudo bash bootstrap.sh

set -e

DOWNLOAD_BASE="https://droneaware.io/node"
INSTALL_DIR="/opt/droneaware"
SCRIPT_DEST="/usr/local/bin/droneaware-setup"
PROFILE_TRIGGER="/etc/profile.d/droneaware-firstboot.sh"

# ANSI colors
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root:  curl -fsSL https://droneaware.io/install | sudo bash"
    exit 1
fi

ARCH=$(uname -m)
if [[ "$ARCH" != "aarch64" ]]; then
    echo -e "${RED}ERROR: DroneAware node software requires a 64-bit Raspberry Pi OS (aarch64).${NC}"
    echo "       Detected architecture: $ARCH"
    echo "       Please flash Raspberry Pi OS Lite (64-bit) and try again."
    exit 1
fi

clear
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║       DroneAware Node Installer  v1.0                        ║${NC}"
echo -e "${BOLD}║       droneaware.io                                           ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo " Installing DroneAware Remote ID sensor software..."
echo ""

# ---------------------------------------------------------------------------
# 1. System dependencies (no Python runtime needed — binaries are self-contained)
# ---------------------------------------------------------------------------
echo -e "${CYAN}[1/3] Installing system dependencies...${NC}"
apt-get update -qq
apt-get install -y --no-install-recommends \
    bluez bluetooth rfkill \
    libglib2.0-dev \
    iw wireless-tools \
    curl >/dev/null 2>&1
systemctl enable bluetooth >/dev/null 2>&1
echo -e "      ${GREEN}Done.${NC}"

# ---------------------------------------------------------------------------
# 2. Download DroneAware files
# ---------------------------------------------------------------------------
echo -e "${CYAN}[2/3] Downloading DroneAware node software...${NC}"

mkdir -p "$INSTALL_DIR"

# Fall back to local files if present (e.g. running from a cloned repo)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

download_file() {
    local filename="$1"
    local dest="${2:-$INSTALL_DIR/$filename}"
    if [[ -f "$SCRIPT_DIR/$filename" ]]; then
        cp "$SCRIPT_DIR/$filename" "$dest"
    else
        curl -fsSL "${DOWNLOAD_BASE}/${filename}" -o "$dest"
    fi
}

# Feeder binaries (compiled ARM64 ELF — no Python required on the node)
download_file "ble_feeder"
download_file "wifi_feeder"
chmod +x "$INSTALL_DIR/ble_feeder" "$INSTALL_DIR/wifi_feeder"

# Setup scripts (bash — remain human-readable)
download_file "initial_setup.sh"
download_file "firstboot.sh"
download_file "droneaware-bt-select"
download_file "README.md" "$INSTALL_DIR/README.md"

chmod +x "$INSTALL_DIR/initial_setup.sh"
chmod +x "$INSTALL_DIR/firstboot.sh"
chmod +x "$INSTALL_DIR/droneaware-bt-select"

# Install wizard as a system-wide command
cp "$INSTALL_DIR/firstboot.sh" "$SCRIPT_DEST"
chmod +x "$SCRIPT_DEST"

echo -e "      ${GREEN}Done.${NC}"

# ---------------------------------------------------------------------------
# 3. First-boot wizard trigger
# ---------------------------------------------------------------------------
echo -e "${CYAN}[3/3] Installing first-boot wizard trigger...${NC}"

cat > "$PROFILE_TRIGGER" <<'PROFILE'
# DroneAware first-boot setup — reminds root to run the wizard on first login
SENTINEL="/opt/droneaware/.configured"
if [ ! -f "$SENTINEL" ] && [ "$EUID" -eq 0 ]; then
    echo ""
    echo "  *** DroneAware setup has not been completed yet. ***"
    echo "  Run: sudo droneaware-setup"
    echo ""
fi
PROFILE

chmod +x "$PROFILE_TRIGGER"
echo -e "      ${GREEN}Done.${NC}"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}Bootstrap complete!${NC}"
echo ""
echo " Next steps:"
echo "   1. Make sure your USB Bluetooth adapter is plugged in"
echo "   2. Run the setup wizard:"
echo ""
echo -e "      ${BOLD}sudo droneaware-setup${NC}"
echo ""
echo " The wizard will assign your node a name, record its location,"
echo " register it on the DroneAware network, and give you a claim link."
echo ""
