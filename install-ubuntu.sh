#!/bin/bash
# DroneAware Feeder Node Installer - Ubuntu/Desktop Edition
# Version: 1.0.15-ubuntu
# Usage: sudo bash install-ubuntu.sh
#
# Compatible with: Ubuntu 20.04+, Debian 11+, Linux Mint, Pop!_OS
# Hardware: Laptops (Dell Latitude, ThinkPad, etc.) or desktops with 
#           built-in or USB Bluetooth/WiFi adapters
#

set -e

INSTALLER_VERSION="v1.0.15-ubuntu"
BINARY_VERSION="v1.0.14"
SERVICE_VERSION="v1.0.6"
GITHUB_REPO="fduflyer/DroneAware-Node-Releases"
INSTALL_DIR="/opt/droneaware"
BIN_DIR="/usr/local/bin"
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
    [[ $EUID -eq 0 ]] || fatal "This installer must be run as root: sudo bash install-ubuntu.sh"
}

# ---------------------------------------------------------------------------
# 1. Terms and Conditions
# ---------------------------------------------------------------------------
show_terms() {
    clear
    echo -e "${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║         DroneAware Feeder Node — Ubuntu Installer v1.0.15          ║"
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
        read -rp "  Do you accept these terms and conditions? [yes/no]: " answer </dev/tty
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
    echo "  Examples: dell-latitude, home-office, livingroom-01"
    echo ""
    while true; do
        read -rp "  Node nickname: " NODE_ID </dev/tty
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
# 3. Node location — mobile vs. static
# ---------------------------------------------------------------------------
prompt_location() {
    heading "Node Location"
    echo ""
    echo "  Is this node fixed in one place, or will it move around"
    echo "  (e.g. carried in a laptop bag or vehicle)"
    echo ""

    while true; do
        read -rp "  Node type — [S]tatic or [M]obile: " loc_type </dev/tty
        case "${loc_type,,}" in
            s|static)
                NODE_MOBILE=false
                _prompt_coordinates
                break
                ;;
            m|mobile)
                NODE_MOBILE=true
                _detect_gps
                break
                ;;
            *)
                warn "Please enter S for Static or M for Mobile."
                ;;
        esac
    done
}

_prompt_coordinates() {
    echo ""
    echo "  Enter the GPS coordinates of this node's fixed location."
    echo ""
    echo "  How to find your coordinates:"
    echo "    1. Open https://maps.google.com in your browser"
    echo "    2. Navigate to the exact spot where this node is installed"
    echo "    3. Right-click on that spot"
    echo "    4. The coordinates appear at the top of the menu — click them to copy"
    echo ""
    echo "    Example: 40.712800, -74.006000"
    echo ""
    echo -e "  ${BOLD}Note:${NC} Your precise location is never publicly visible. DroneAware"
    echo "  displays only a 2-mile detection ring around your node — your exact"
    echo "  coordinates are kept private."
    echo ""

    while true; do
        read -rp "  Latitude  (e.g. 40.712800): " NODE_LAT </dev/tty
        NODE_LAT="${NODE_LAT// /}"
        if [[ "$NODE_LAT" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && \
           awk -v v="$NODE_LAT" 'BEGIN{exit !(v>=-90&&v<=90)}'; then
            break
        fi
        warn "Invalid latitude. Must be a number between -90 and 90."
    done

    while true; do
        read -rp "  Longitude (e.g. -74.006000): " NODE_LON </dev/tty
        NODE_LON="${NODE_LON// /}"
        if [[ "$NODE_LON" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && \
           awk -v v="$NODE_LON" 'BEGIN{exit !(v>=-180&&v<=180)}'; then
            break
        fi
        warn "Invalid longitude. Must be a number between -180 and 180."
    done

    info "Location set: $NODE_LAT, $NODE_LON"
    GPS_DEVICE=""
}

_detect_gps() {
    heading "Detecting USB GPS"
    GPS_DEVICE=""
    NODE_LAT=""
    NODE_LON=""

    for dev in /dev/ttyUSB* /dev/ttyACM*; do
        [[ -e "$dev" ]] || continue
        GPS_DEVICE="$dev"
        info "USB GPS device detected: $GPS_DEVICE"
        break
    done

    if [[ -z "$GPS_DEVICE" ]]; then
        warn "No USB GPS device detected."
        warn "For mobile operation, connect a USB GPS module (e.g. u-blox 7/8)."
        warn "Without GPS, detections will have no location data."
    fi
}

# ---------------------------------------------------------------------------
# 4. Detect WiFi adapter (internal or USB)
# ---------------------------------------------------------------------------
detect_wifi_adapter() {
    heading "Detecting WiFi Adapter"
    WIFI_ADAPTER=""

    # First try USB adapters (preferred for monitor mode)
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

    # Fall back to internal WiFi if no USB adapter found
    if [[ -z "$WIFI_ADAPTER" ]]; then
        for iface_path in /sys/class/net/wlan*/; do
            [[ -d "$iface_path" ]] || continue
            iface=$(basename "$iface_path")
            WIFI_ADAPTER="$iface"
            warn "No USB WiFi adapter found. Using internal adapter: $WIFI_ADAPTER"
            warn "Note: Many internal laptop WiFi cards don't support monitor mode."
            warn "For best results, use an external adapter (Alfa AWUS036N recommended)."
            break
        done
    fi

    if [[ -z "$WIFI_ADAPTER" ]]; then
        warn "No WiFi adapter detected."
        warn "WiFi capture will be disabled. Bluetooth-only operation is still functional."
    fi
}

# ---------------------------------------------------------------------------
# 5. Configure NetworkManager for monitor mode (if WiFi detected)
# ---------------------------------------------------------------------------
configure_network_manager() {
    if [[ -z "$WIFI_ADAPTER" ]]; then
        info "Skipping NetworkManager configuration (no WiFi adapter)."
        return
    fi

    heading "Configuring NetworkManager"
    
    # Persist existing profiles
    local count=0
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        local fname
        fname=$(nmcli -f FILENAME con show "$name" 2>/dev/null | awk 'NR==2{print $1}')
        if [[ "$fname" != /etc/NetworkManager/system-connections/* ]]; then
            nmcli con modify "$name" connection.autoconnect yes 2>/dev/null || true
            count=$((count + 1))
            info "Persisted: $name"
        fi
    done < <(nmcli -t -f NAME,TYPE con show 2>/dev/null | grep "802-11-wireless" | cut -d: -f1)

    if [[ $count -gt 0 ]]; then
        info "$count WiFi profile(s) secured."
    fi

    # Set adapter as unmanaged for monitor mode
    mkdir -p /etc/NetworkManager/conf.d
    cat > /etc/NetworkManager/conf.d/droneaware.conf <<EOF
# DroneAware — prevent NetworkManager from managing the monitor adapter.
[keyfile]
unmanaged-devices=interface-name:${WIFI_ADAPTER}
EOF
    
    nmcli device set "${WIFI_ADAPTER}" managed no > /dev/null 2>&1 || true
    info "${WIFI_ADAPTER} set as unmanaged (monitor-only) in NetworkManager."
}

# ---------------------------------------------------------------------------
# 6. System packages
# ---------------------------------------------------------------------------
install_packages() {
    heading "Installing System Packages"
    
    # Update package lists
    apt-get update -qq
    
    # Install required packages
    apt-get install -y --no-install-recommends \
        bluez bluetooth iw rfkill curl python3-pip python3-venv \
        libbluetooth-dev tcpdump dumpcap net-tools rtl-sdr librtlsdr-dev \
        > /dev/null 2>&1
    
    # Enable Bluetooth service
    systemctl enable bluetooth > /dev/null 2>&1
    systemctl start bluetooth  > /dev/null 2>&1
    
    info "System packages ready."
}

# ---------------------------------------------------------------------------
# 7. Install Python dependencies
# ---------------------------------------------------------------------------
install_python_deps() {
    heading "Installing Python Dependencies"
    
    # Create virtual environment
    mkdir -p "$INSTALL_DIR"
    python3 -m venv "$INSTALL_DIR/venv"
    
    # Activate and install packages
    source "$INSTALL_DIR/venv/bin/activate"
    pip install --upgrade pip > /dev/null 2>&1
    pip install bleak requests pyrtlsdr > /dev/null 2>&1
    
    info "Python dependencies installed in $INSTALL_DIR/venv"
}

# ---------------------------------------------------------------------------
# 8. Copy Python scripts from source
# ---------------------------------------------------------------------------
copy_scripts() {
    heading "Installing DroneAware Scripts"
    
    # Copy feeder scripts
    cp /workspace/ble_feeder.py "$INSTALL_DIR/"
    cp /workspace/wifi_feeder.py "$INSTALL_DIR/"
    cp /workspace/sdr_feeder.py "$INSTALL_DIR/"
    cp /workspace/api.py "$INSTALL_DIR/" 2>/dev/null || true
    
    chmod +x "$INSTALL_DIR"/*.py
    
    info "Scripts installed to $INSTALL_DIR"
}

# ---------------------------------------------------------------------------
# 9. Install systemd services
# ---------------------------------------------------------------------------
install_services() {
    heading "Installing Services"
    
    # Copy standalone service files from workspace (preferred method)
    if [[ -f /workspace/droneaware-ble.service ]]; then
        cp /workspace/droneaware-ble.service /etc/systemd/system/
        info "Installed droneaware-ble.service from workspace"
    else
        # Fallback: create inline service file with correct configuration
        cat > /etc/systemd/system/droneaware-ble.service <<EOF
[Unit]
Description=DroneAware BLE Remote ID Feeder
After=bluetooth.service network-online.target droneaware-bt-select.service
Wants=bluetooth.service network-online.target
Requires=droneaware-bt-select.service

[Service]
Type=simple
User=root
EnvironmentFile=/opt/droneaware/config.env
Environment=PATH=$INSTALL_DIR/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
WorkingDirectory=$INSTALL_DIR
ExecStartPre=/usr/sbin/rfkill unblock bluetooth
ExecStart=$INSTALL_DIR/venv/bin/python3 $INSTALL_DIR/ble_feeder.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=droneaware-ble

[Install]
WantedBy=multi-user.target
EOF
    fi

    if [[ -f /workspace/droneaware-wifi.service ]]; then
        cp /workspace/droneaware-wifi.service /etc/systemd/system/
        info "Installed droneaware-wifi.service from workspace"
    else
        # Fallback: create inline service file with correct configuration
        cat > /etc/systemd/system/droneaware-wifi.service <<EOF
[Unit]
Description=DroneAware WiFi Remote ID Feeder
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
EnvironmentFile=/opt/droneaware/config.env
Environment=PATH=$INSTALL_DIR/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/venv/bin/python3 $INSTALL_DIR/wifi_feeder.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=droneaware-wifi

[Install]
WantedBy=multi-user.target
EOF
    fi

    if [[ -f /workspace/droneaware-sdr.service ]]; then
        cp /workspace/droneaware-sdr.service /etc/systemd/system/
        info "Installed droneaware-sdr.service from workspace"
    else
        # Fallback: create inline service file with correct configuration
        cat > /etc/systemd/system/droneaware-sdr.service <<EOF
[Unit]
Description=DroneAware RTL-SDR Remote ID Feeder
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
EnvironmentFile=/opt/droneaware/config.env
Environment=PATH=$INSTALL_DIR/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/venv/bin/python3 $INSTALL_DIR/sdr_feeder.py --freq-dwell \${FREQ_DWELL:-0.5} --gain \${SDR_GAIN:-auto}
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=droneaware-sdr

[Install]
WantedBy=multi-user.target
EOF
    fi

    # Install bt-select service if available
    if [[ -f /workspace/droneaware-bt-select.service ]]; then
        cp /workspace/droneaware-bt-select.service /etc/systemd/system/
        info "Installed droneaware-bt-select.service from workspace"
    fi

    # Install RTL-SDR udev rules for USB permissions
    if [[ ! -f /etc/udev/rules.d/20-rtl-sdr.rules ]]; then
        cat > /etc/udev/rules.d/20-rtl-sdr.rules <<EOF
# RTL-SDR Blog v3 USB permissions
ATTR{idVendor}=="0bda", ATTR{idProduct}=="2838", MODE="0666", GROUP="plugdev"
EOF
        udevadm control --reload-rules
        info "Installed RTL-SDR udev rules"
    fi

    systemctl daemon-reload
    systemctl enable droneaware-ble droneaware-wifi droneaware-sdr droneaware-bt-select > /dev/null 2>&1 || true
    
    info "Services enabled for autostart."
}

# ---------------------------------------------------------------------------
# 10. Write config.env
# ---------------------------------------------------------------------------
write_config() {
    heading "Writing Configuration"
    mkdir -p "$INSTALL_DIR"
    mkdir -p /etc/droneaware

    # Detect BT adapter MAC
    BLE_ADAPTER="hci0"
    BLE_ADAPTER_MAC=$(hciconfig hci0 2>/dev/null | awk '/BD Address/{print $3}' || true)
    [[ -z "$BLE_ADAPTER_MAC" ]] && BLE_ADAPTER_MAC="00:00:00:00:00:00"

    cat > "${INSTALL_DIR}/config.env" <<EOF
NODE_ID=${NODE_ID}
SERVER_URL=${SERVER_URL}
BLE_ADAPTER=${BLE_ADAPTER}
BLE_ADAPTER_MAC=${BLE_ADAPTER_MAC}
WIFI_ADAPTER=${WIFI_ADAPTER:-}
NODE_MOBILE=${NODE_MOBILE}
NODE_LAT=${NODE_LAT:-}
NODE_LON=${NODE_LON:-}
GPS_DEVICE=${GPS_DEVICE:-}
BATCH_SIZE=200
FLUSH_INTERVAL=5.0
FREQ_DWELL=0.5
SDR_GAIN=auto
EOF
    chmod 600 "${INSTALL_DIR}/config.env"
    info "Configuration written to ${INSTALL_DIR}/config.env"
}

# ---------------------------------------------------------------------------
# 11. Enroll node
# ---------------------------------------------------------------------------
enroll_node() {
    heading "Node Enrollment"
    echo ""
    echo "  To enroll this node you need a DroneAware account."
    echo ""
    echo -e "  1. Open ${BOLD}https://droneaware.io/nodes${NC} in your browser"
    echo "  2. Log in (or create a free account)"
    echo -e "  3. Click ${BOLD}Add Node${NC}"
    echo "  4. Accept the Contributor Agreement if prompted"
    echo "  5. Copy the enrollment token shown (valid for 15 minutes)"
    echo ""

    local enrollment_token
    while true; do
        read -rp "  Paste enrollment token: " enrollment_token </dev/tty
        enrollment_token="${enrollment_token// /}"
        [[ -n "$enrollment_token" ]] && break
        warn "Enrollment token cannot be empty."
    done

    # Build JSON-safe values
    local lat_json lon_json has_gps_json
    if [[ -n "${NODE_LAT:-}" ]]; then
        lat_json="${NODE_LAT}"
        lon_json="${NODE_LON}"
    else
        lat_json="null"
        lon_json="null"
    fi
    [[ -n "${GPS_DEVICE:-}" ]] && has_gps_json="true" || has_gps_json="false"

    while true; do
        echo ""
        echo "  Contacting DroneAware network..."

        local http_status response
        http_status=$(curl -s --max-time 15 \
            -o /tmp/droneaware_enroll.json \
            -w "%{http_code}" \
            -H "Content-Type: application/json" \
            -d "{\"node_id\":\"${NODE_ID}\",\"enrollment_token\":\"${enrollment_token}\",\"mobile\":${NODE_MOBILE},\"has_gps\":${has_gps_json},\"lat\":${lat_json},\"lon\":${lon_json}}" \
            "${SERVER_URL}/node/enroll" 2>/dev/null) || true
        response=$(cat /tmp/droneaware_enroll.json 2>/dev/null || true)

        if [[ -z "$http_status" || "$http_status" == "000" ]]; then
            rm -f /tmp/droneaware_enroll.json
            fatal "Enrollment request failed. Check your internet connection and try again."
        fi

        if [[ "$http_status" == "409" ]]; then
            warn "That node name is already taken. Please choose a different name."
            echo ""
            while true; do
                read -rp "  New node nickname: " NODE_ID </dev/tty
                NODE_ID="${NODE_ID// /-}"
                NODE_ID="${NODE_ID,,}"
                if [[ -z "$NODE_ID" ]]; then
                    warn "Nickname cannot be empty."
                elif [[ ! "$NODE_ID" =~ ^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$ ]]; then
                    warn "Use 3–32 lowercase letters, numbers, or hyphens."
                else
                    info "Node ID: $NODE_ID"
                    sed -i "s/^NODE_ID=.*/NODE_ID=${NODE_ID}/" "${INSTALL_DIR}/config.env"
                    break
                fi
            done
            continue
        elif [[ "$http_status" == "200" || "$http_status" == "201" ]]; then
            local node_credential
            node_credential=$(echo "$response" | grep -oP '"node_credential"\s*:\s*"\K[^"]+' || true)
            if [[ -z "$node_credential" ]]; then
                rm -f /tmp/droneaware_enroll.json
                fatal "Enrollment failed: server returned success but no credential."
            fi
            echo "$node_credential" > /etc/droneaware/token
            chmod 600 /etc/droneaware/token
            rm -f /tmp/droneaware_enroll.json
            info "Node enrolled and credential saved."
            break
        else
            local error_msg
            error_msg=$(echo "$response" | grep -oP '"detail"\s*:\s*"\K[^"]+' || true)
            rm -f /tmp/droneaware_enroll.json
            if [[ -n "$error_msg" ]]; then
                fatal "Enrollment failed: ${error_msg}"
            fi
            fatal "Enrollment failed (HTTP ${http_status}). Token may have expired."
        fi
    done
}

# ---------------------------------------------------------------------------
# 12. Print summary
# ---------------------------------------------------------------------------
print_summary() {
    echo ""
    echo -e "${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║              Installation Complete!                                  ║"
    echo "╠══════════════════════════════════════════════════════════════════════╣"
    printf  "║  Node ID : %-57s║\n" "$NODE_ID"
    echo  "╠══════════════════════════════════════════════════════════════════════╣"
    echo  "║  Your node is enrolled and active on the DroneAware network.       ║"
    echo  "║  View it at: https://droneaware.io/nodes                           ║"
    echo  "╠══════════════════════════════════════════════════════════════════════╣"
    echo  "║  Start services:  sudo systemctl start droneaware-ble              ║"
    echo  "║                 sudo systemctl start droneaware-wifi               ║"
    echo  "║                                                                    ║"
    echo  "║  View logs:     journalctl -u droneaware-ble -f                    ║"
    echo  "║                 journalctl -u droneaware-wifi -f                   ║"
    echo  "╠══════════════════════════════════════════════════════════════════════╣"
    echo  "║  NOTE: For WiFi monitor mode, ensure your adapter supports it.     ║"
    echo  "║  Many internal laptop WiFi cards have limited monitor mode support.║"
    echo  "║  Recommended: Alfa AWUS036N USB adapter                            ║"
    echo  "╚══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
require_root
accept_terms
prompt_node_id
prompt_location
detect_wifi_adapter
configure_network_manager
install_packages
install_python_deps
copy_scripts
install_services
write_config
enroll_node
print_summary
