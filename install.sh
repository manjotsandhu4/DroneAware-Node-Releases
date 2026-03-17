#!/bin/bash
# DroneAware Feeder Node Installer
# Version: 1.0.0
# Usage:  sudo bash install.sh
#
# Requires: Raspberry Pi OS Bookworm 64-bit, internet connection,
#           USB BT dongle (UD100 or equivalent), USB WiFi adapter (Alfa AWUS036N or equivalent)

set -e

RELEASE_TAG="v1.0.0"
GITHUB_REPO="fduflyer/DroneAware-Node"
INSTALL_DIR="/opt/droneaware"
BIN_DIR="/usr/local/bin"
ENROLLMENT_SECRET="cbb1348c-33bd-4b52-abae-24892961d862"
SERVER_URL="https://api.droneaware.io/api"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "  ${GREEN}✓${NC}  $*"; }
warn()    { echo -e "  ${YELLOW}!${NC}  $*"; }
fatal()   { echo -e "\n  ${RED}✗  ERROR: $*${NC}\n"; exit 1; }
heading() { echo -e "\n${BOLD}$*${NC}"; }

require_root() {
    [[ $EUID -eq 0 ]] || fatal "This installer must be run as root: sudo bash install.sh"
}

# ---------------------------------------------------------------------------
# 1. Terms and Conditions
# ---------------------------------------------------------------------------
show_terms() {
    clear
    echo -e "${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║            DroneAware Feeder Node — Installer v1.0.0               ║"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    echo -e "${BOLD}ACCEPTANCE UPON NODE REGISTRATION${NC}"
    echo ""
    echo "  BINDING ACCEPTANCE"
    echo "  You are entering into and agreeing to be legally bound by the"
    echo "  DroneAware Feeder Node Contributor Agreement at the time you claim"
    echo "  or activate a Node."
    echo ""
    echo "  CONDITION OF PARTICIPATION"
    echo "  Acceptance of this Agreement is a mandatory condition of registering"
    echo "  or operating any Node on the DroneAware network. You may not transmit"
    echo "  data to DroneAware systems without accepting this Agreement."
    echo ""
    echo "  DATA OWNERSHIP ASSIGNMENT"
    echo "  As a condition of Node registration and operation, you agree that all"
    echo "  data transmitted from your Node is subject to the Data Ownership"
    echo "  Assignment provisions of this Agreement, including the irrevocable"
    echo "  assignment of all rights, title, and interest to DroneAware, LLC."
    echo ""
    echo "  AFFIRMATIVE ACTION REQUIRED"
    echo "  Acceptance requires an affirmative action during Node registration."
    echo ""
    echo "  RECORD OF ACCEPTANCE"
    echo "  DroneAware may record and retain evidence of your acceptance,"
    echo "  including: timestamp, IP address, account identity, and agreement"
    echo "  version. Such records shall constitute proof of your agreement."
    echo ""
    echo "  NO OPERATION WITHOUT ACCEPTANCE"
    echo "  If you do not accept this Agreement, you are not authorized to"
    echo "  register a Node, connect a Node to the network, or transmit any"
    echo "  data to DroneAware."
    echo ""
    echo "──────────────────────────────────────────────────────────────────────"
    echo ""
}

accept_terms() {
    show_terms
    while true; do
        read -rp "  Do you accept these terms and conditions? [yes/no]: " answer
        case "${answer,,}" in
            yes)
                info "Terms accepted."
                echo ""
                break
                ;;
            no)
                echo ""
                echo "  Installation cancelled. You must accept the terms to use DroneAware."
                echo ""
                exit 0
                ;;
            *)
                warn "Please type 'yes' to accept or 'no' to decline."
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# 2. Collect node nickname
# ---------------------------------------------------------------------------
prompt_node_id() {
    heading "Node Setup"
    echo ""
    echo "  Choose a short nickname for this node (letters, numbers, hyphens)."
    echo "  This will identify your node on the DroneAware network."
    echo "  Examples: my-garage, rooftop-east, backyard-01"
    echo ""
    while true; do
        read -rp "  Node nickname: " NODE_ID
        NODE_ID="${NODE_ID// /-}"
        NODE_ID="${NODE_ID,,}"
        if [[ -z "$NODE_ID" ]]; then
            warn "Nickname cannot be empty."
        elif [[ ! "$NODE_ID" =~ ^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$ ]]; then
            warn "Use 3–32 lowercase letters, numbers, or hyphens. Cannot start/end with a hyphen."
        else
            info "Node ID: $NODE_ID"
            break
        fi
    done
}

# ---------------------------------------------------------------------------
# 3. Detect external USB WiFi adapter
# ---------------------------------------------------------------------------
detect_wifi_adapter() {
    heading "Detecting WiFi Adapter"
    WIFI_ADAPTER=""

    for iface_path in /sys/class/net/wlan*/; do
        [[ -d "$iface_path" ]] || continue
        iface=$(basename "$iface_path")
        subsystem=$(readlink -f "${iface_path}device/subsystem" 2>/dev/null || true)
        if [[ "$subsystem" == */usb* ]]; then
            WIFI_ADAPTER="$iface"
            info "Found USB WiFi adapter: $WIFI_ADAPTER"
            break
        fi
    done

    if [[ -z "$WIFI_ADAPTER" ]]; then
        warn "No USB WiFi adapter detected."
        warn "Connect your Alfa AWUS036N (or compatible adapter) and re-run this installer."
        fatal "USB WiFi adapter required."
    fi
}

# ---------------------------------------------------------------------------
# 4. System packages
# ---------------------------------------------------------------------------
install_packages() {
    heading "Installing System Packages"
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        bluez bluetooth iw rfkill curl \
        > /dev/null 2>&1
    systemctl enable bluetooth > /dev/null 2>&1
    systemctl start bluetooth  > /dev/null 2>&1
    info "System packages ready."
}

# ---------------------------------------------------------------------------
# 5. Download binaries from GitHub Release
# ---------------------------------------------------------------------------
download_binaries() {
    heading "Downloading DroneAware Binaries ($RELEASE_TAG)"
    local base_url="https://github.com/${GITHUB_REPO}/releases/download/${RELEASE_TAG}"
    mkdir -p "$BIN_DIR"

    for binary in ble_feeder wifi_feeder; do
        echo "    Downloading $binary..."
        curl -fsSL --retry 3 \
            "${base_url}/${binary}" \
            -o "${BIN_DIR}/${binary}"
        chmod +x "${BIN_DIR}/${binary}"
        info "$binary → ${BIN_DIR}/${binary}"
    done
}

# ---------------------------------------------------------------------------
# 6. Install bt-select script and service files
# ---------------------------------------------------------------------------
install_services() {
    heading "Installing Services"
    local base_url="https://github.com/${GITHUB_REPO}/releases/download/${RELEASE_TAG}"

    # bt-select helper
    curl -fsSL --retry 3 \
        "${base_url}/droneaware-bt-select" \
        -o "${BIN_DIR}/droneaware-bt-select"
    chmod +x "${BIN_DIR}/droneaware-bt-select"
    info "droneaware-bt-select installed."

    # Systemd service files
    for svc in droneaware-bt-select.service droneaware-ble.service droneaware-wifi.service; do
        curl -fsSL --retry 3 \
            "${base_url}/${svc}" \
            -o "/etc/systemd/system/${svc}"
        info "$svc installed."
    done

    systemctl daemon-reload
    systemctl enable droneaware-bt-select droneaware-ble droneaware-wifi > /dev/null 2>&1
    info "Services enabled for autostart."
}

# ---------------------------------------------------------------------------
# 7. Write config.env
# ---------------------------------------------------------------------------
write_config() {
    heading "Writing Configuration"
    mkdir -p "$INSTALL_DIR"
    mkdir -p /etc/droneaware

    # Detect BT adapter MAC — bt-select will refine on first boot
    BLE_ADAPTER="hci0"
    BLE_ADAPTER_MAC=$(hciconfig hci0 2>/dev/null | awk '/BD Address/{print $3}' || true)
    [[ -z "$BLE_ADAPTER_MAC" ]] && BLE_ADAPTER_MAC="00:00:00:00:00:00"

    cat > "${INSTALL_DIR}/config.env" <<EOF
NODE_ID=${NODE_ID}
SERVER_URL=${SERVER_URL}
BLE_ADAPTER=${BLE_ADAPTER}
BLE_ADAPTER_MAC=${BLE_ADAPTER_MAC}
WIFI_ADAPTER=${WIFI_ADAPTER}
BATCH_SIZE=200
FLUSH_INTERVAL=5.0
ENROLLMENT_SECRET=${ENROLLMENT_SECRET}
EOF
    chmod 600 "${INSTALL_DIR}/config.env"
    info "Configuration written to ${INSTALL_DIR}/config.env"
}

# ---------------------------------------------------------------------------
# 8. Enroll node
# ---------------------------------------------------------------------------
enroll_node() {
    heading "Enrolling Node with DroneAware Network"
    echo "  Contacting droneaware.io..."

    # Run feeder briefly — it enrolls, saves token, writes claim.txt, then we kill it
    "${BIN_DIR}/ble_feeder" \
        --node-id "$NODE_ID" \
        --server "$SERVER_URL" \
        --enrollment-secret "$ENROLLMENT_SECRET" \
        --adapter-mac "$BLE_ADAPTER_MAC" \
        > /tmp/droneaware-enroll.log 2>&1 &
    local pid=$!
    sleep 15
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    if [[ -f /etc/droneaware/claim.txt ]]; then
        CLAIM_CODE=$(grep "^Claim code:" /etc/droneaware/claim.txt | awk '{print $3}')
        CLAIM_URL=$(grep "^Claim URL:"  /etc/droneaware/claim.txt | awk '{print $3}')
        info "Node enrolled successfully."
    else
        warn "Enrollment may have failed — claim info not found."
        warn "Check: sudo journalctl -u droneaware-ble"
        CLAIM_CODE=""
        CLAIM_URL=""
    fi
}

# ---------------------------------------------------------------------------
# 9. Print summary
# ---------------------------------------------------------------------------
print_summary() {
    local w=70
    echo ""
    echo -e "${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║                    Installation Complete!                           ║"
    echo "╠══════════════════════════════════════════════════════════════════════╣"
    printf  "║  Node ID   : %-55s║\n" "$NODE_ID"
    if [[ -n "$CLAIM_CODE" ]]; then
        printf "║  Claim Code: %-55s║\n" "$CLAIM_CODE"
        printf "║  Claim URL : %-55s║\n" "$CLAIM_URL"
        echo  "╠══════════════════════════════════════════════════════════════════════╣"
        echo  "║  NEXT STEP: Visit the Claim URL above to activate your node on     ║"
        echo  "║  the DroneAware network.                                            ║"
    else
        echo  "╠══════════════════════════════════════════════════════════════════════╣"
        echo  "║  NEXT STEP: Enrollment did not complete automatically.              ║"
        echo  "║  Run: sudo journalctl -u droneaware-ble -f  to diagnose.           ║"
    fi
    echo  "╠══════════════════════════════════════════════════════════════════════╣"
    echo  "║  Feeders will start automatically on next reboot.                  ║"
    echo  "║  To start now:  sudo systemctl start droneaware-ble droneaware-wifi║"
    echo  "║  To view logs:  journalctl -u droneaware-ble -f                    ║"
    echo  "╚══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
require_root
accept_terms
prompt_node_id
detect_wifi_adapter
install_packages
download_binaries
install_services
write_config
enroll_node
print_summary
