#!/bin/bash
# DroneAware Node First-Boot Setup Wizard
#
# Runs automatically on first SSH/console login via /etc/profile.d/droneaware-firstboot.sh
# Can also be run manually at any time: sudo droneaware-setup
#
# What this does:
#   1. Verifies internet connectivity
#   2. Assigns a Node ID (auto-generated from BT dongle MAC)
#   3. Collects sensor location (lat / lon / elevation AGL)
#   4. Installs the DroneAware feeder software
#   5. Enrolls the node and displays the claim URL
#   6. Starts the feeder services

SENTINEL="/opt/droneaware/.configured"
INSTALL_DIR="/opt/droneaware"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUD_API="https://api.droneaware.io/api"
ENROLLMENT_SECRET="cbb1348c-33bd-4b52-abae-24892961d862"
TOKEN_FILE="/etc/droneaware/token"
CLAIM_FILE="/etc/droneaware/claim.txt"

# ANSI colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------
if [ -f "$SENTINEL" ]; then
    echo "This node is already configured."
    echo "To re-run setup: sudo rm $SENTINEL && sudo droneaware-setup"
    exit 0
fi

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root:  sudo droneaware-setup"
    exit 1
fi

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
clear
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║       DroneAware Node Setup Wizard  v1.0                     ║${NC}"
echo -e "${BOLD}║       Remote ID Sensor Network  —  droneaware.io             ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo " This wizard will guide you through:"
echo "   1. Verifying your internet connection"
echo "   2. Assigning a unique ID to this node"
echo "   3. Recording where this sensor is located"
echo "   4. Installing the DroneAware feeder software"
echo "   5. Registering this node and giving you a claim link"
echo ""
echo " Estimated time: 3 – 5 minutes"
echo ""
read -rp " Press ENTER to begin, or Ctrl+C to exit: "
echo ""

# ---------------------------------------------------------------------------
# Step 1: Network
# ---------------------------------------------------------------------------
echo -e "${CYAN}[1/5] Checking internet connection...${NC}"

NET_OK=false
for i in $(seq 1 12); do
    if curl -sf --max-time 5 https://api.droneaware.io/health >/dev/null 2>&1 || \
       ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        NET_OK=true
        break
    fi
    printf "      Waiting for network... attempt %d of 12\r" "$i"
    sleep 5
done

if ! $NET_OK; then
    echo ""
    echo -e "${RED}ERROR: No internet connection detected after 60 seconds.${NC}"
    echo ""
    echo " Options:"
    echo "   Ethernet  — plug in a cable and run this wizard again"
    echo "   WiFi      — add your credentials to /boot/wpa_supplicant.conf then reboot:"
    echo ""
    echo "     country=US"
    echo "     ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev"
    echo "     update_config=1"
    echo "     network={"
    echo '       ssid="YourNetworkName"'
    echo '       psk="YourPassword"'
    echo "     }"
    echo ""
    exit 1
fi

echo -e "      ${GREEN}Connected.${NC}"
echo ""

# ---------------------------------------------------------------------------
# Step 2: Node ID
# ---------------------------------------------------------------------------
echo -e "${CYAN}[2/5] Assigning Node ID...${NC}"
echo ""

# Detect USB BT dongle MAC → auto-generate ID
detect_usb_bt_mac() {
    for hci in /sys/class/bluetooth/hci*; do
        [[ -d "$hci" ]] || continue
        uevent="$hci/device/uevent"
        [[ -f "$uevent" ]] || continue
        if grep -q "DEVTYPE=usb_interface" "$uevent"; then
            local hci_name mac
            hci_name=$(basename "$hci")
            mac=$(hciconfig "$hci_name" 2>/dev/null \
                | grep -oP 'BD Address:\s+\K[0-9A-Fa-f:]{17}' | head -1)
            [[ -n "$mac" ]] && echo "$mac" && return 0
        fi
    done
    return 1
}

BT_MAC=$(detect_usb_bt_mac || true)

if [[ -n "$BT_MAC" ]]; then
    LAST4=$(echo "$BT_MAC" | tr -d ':' | rev | cut -c1-4 | rev | tr '[:lower:]' '[:upper:]')
    SUGGESTED_ID="DA-${LAST4}"
    echo "      Detected USB Bluetooth adapter: $BT_MAC"
    echo -e "      Suggested Node ID: ${BOLD}${SUGGESTED_ID}${NC}"
    echo ""
    read -rp "      Press ENTER to accept, or type a custom ID: " CUSTOM_ID
    NODE_ID="${CUSTOM_ID:-$SUGGESTED_ID}"
else
    echo -e "      ${YELLOW}No USB Bluetooth adapter detected.${NC}"
    echo "      Make sure the USB BT dongle is plugged in before running this wizard."
    echo "      You can continue without it — enter a custom Node ID."
    echo ""
    read -rp "      Node ID (e.g. DA-MYSPOT): " NODE_ID
    while [[ -z "$NODE_ID" ]]; do
        read -rp "      Node ID cannot be empty: " NODE_ID
    done
fi

echo ""
echo -e "      Node ID: ${BOLD}${NODE_ID}${NC}"
echo ""

# ---------------------------------------------------------------------------
# Step 3: Location
# ---------------------------------------------------------------------------
echo -e "${CYAN}[3/5] Sensor Location${NC}"
echo ""
echo " DroneAware uses your sensor's location to map drone detections on"
echo " the live dashboard. Please provide accurate coordinates."
echo ""
echo " HOW TO FIND YOUR COORDINATES:"
echo "   Google Maps  — right-click your antenna location, copy the coordinates"
echo "   iPhone Maps  — tap & hold your location, read from the top"
echo "   Google Earth — hover your cursor over the antenna spot"
echo ""
echo " ELEVATION ABOVE GROUND (meters):"
echo "   How high is the antenna above the ground directly below it?"
echo "   Not altitude above sea level — just the mounting height."
echo "   Examples: 3 m = ground-floor window, 6 m = rooftop, 12 m = light pole"
echo ""

read -rp " Latitude  (decimal, e.g.  40.4578): " NODE_LAT
while ! echo "$NODE_LAT" | grep -qP '^-?\d+(\.\d+)?$'; do
    echo "   Use decimal degrees — not DMS. Example: 40.4578 or -33.8688"
    read -rp " Latitude: " NODE_LAT
done

read -rp " Longitude (decimal, e.g. -74.3392): " NODE_LON
while ! echo "$NODE_LON" | grep -qP '^-?\d+(\.\d+)?$'; do
    echo "   Use decimal degrees — not DMS. Example: -74.3392 or 151.2093"
    read -rp " Longitude: " NODE_LON
done

read -rp " Elevation above ground in meters [5]: " NODE_ELEVATION
NODE_ELEVATION="${NODE_ELEVATION:-5}"
while ! echo "$NODE_ELEVATION" | grep -qP '^\d+(\.\d+)?$'; do
    read -rp " Enter a number (e.g. 5): " NODE_ELEVATION
    NODE_ELEVATION="${NODE_ELEVATION:-5}"
done

echo ""
echo "      Location confirmed: ${NODE_LAT}, ${NODE_LON}  |  ${NODE_ELEVATION} m AGL"
echo ""

# ---------------------------------------------------------------------------
# Step 4: Install software
# ---------------------------------------------------------------------------
echo -e "${CYAN}[4/5] Installing DroneAware feeder software...${NC}"
echo ""

bash "$SCRIPT_DIR/initial_setup.sh" \
    "$NODE_ID" \
    "$CLOUD_API" \
    "" \
    "$ENROLLMENT_SECRET" \
    "$NODE_LAT" \
    "$NODE_LON" \
    "$NODE_ELEVATION"

echo ""

# ---------------------------------------------------------------------------
# Step 5: Enroll node and display claim URL
# ---------------------------------------------------------------------------
echo -e "${CYAN}[5/5] Registering node with the DroneAware network...${NC}"
echo ""

ENROLL_PAYLOAD=$(printf \
    '{"node_id":"%s","enrollment_secret":"%s","lat":%s,"lon":%s,"elevation_agl_m":%s}' \
    "$NODE_ID" "$ENROLLMENT_SECRET" "$NODE_LAT" "$NODE_LON" "$NODE_ELEVATION")

ENROLL_RESPONSE=$(curl -sf --max-time 15 \
    -H "Content-Type: application/json" \
    -d "$ENROLL_PAYLOAD" \
    "${CLOUD_API}/node/enroll" 2>/dev/null) || true

if [[ -z "$ENROLL_RESPONSE" ]]; then
    echo -e "      ${YELLOW}Enrollment request failed — will retry on next service start.${NC}"
    echo "      The feeder services will still run and collect data."
else
    AUTH_TOKEN=$(echo "$ENROLL_RESPONSE" | grep -oP '"auth_token"\s*:\s*"\K[^"]+' || true)
    CLAIM_CODE=$(echo "$ENROLL_RESPONSE"  | grep -oP '"claim_code"\s*:\s*"\K[^"]+' || true)
    CLAIM_URL=$(echo "$ENROLL_RESPONSE"   | grep -oP '"claim_url"\s*:\s*"\K[^"]+' || true)

    if [[ -n "$AUTH_TOKEN" ]]; then
        mkdir -p /etc/droneaware
        echo "$AUTH_TOKEN" > "$TOKEN_FILE"
        # Inject token into config.env so service picks it up without re-enrolling
        sed -i "s|^NODE_TOKEN=.*|NODE_TOKEN=$AUTH_TOKEN|" "$INSTALL_DIR/config.env"
        echo -e "      ${GREEN}Node registered successfully.${NC}"
    fi

    if [[ -n "$CLAIM_CODE" && -n "$CLAIM_URL" ]]; then
        mkdir -p /etc/droneaware
        {
            echo "Node: $NODE_ID"
            echo "Claim URL: $CLAIM_URL"
            echo "Claim code: $CLAIM_CODE"
        } > "$CLAIM_FILE"
        echo ""
        echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}║  Your node is enrolled! Link it to your account below.       ║${NC}"
        echo -e "${BOLD}║                                                              ║${NC}"
        printf "${BOLD}║  Claim URL:  %-49s║${NC}\n" "$CLAIM_URL"
        printf "${BOLD}║  Code:       %-49s║${NC}\n" "$CLAIM_CODE"
        echo -e "${BOLD}║                                                              ║${NC}"
        echo -e "${BOLD}║  This link expires in 48 hours.                              ║${NC}"
        echo -e "${BOLD}║  Saved to: /etc/droneaware/claim.txt                         ║${NC}"
        echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
    fi
fi

# ---------------------------------------------------------------------------
# Start services and write sentinel
# ---------------------------------------------------------------------------
touch "$SENTINEL"

systemctl daemon-reload
systemctl start droneaware-ble  2>/dev/null || true
systemctl start droneaware-wifi 2>/dev/null || true

echo ""
echo -e "${GREEN}${BOLD}Setup complete!  Node ${NODE_ID} is now live on the DroneAware network.${NC}"
echo ""
echo " Useful commands:"
echo "   sudo journalctl -u droneaware-ble -f     # live BLE feeder log"
echo "   sudo journalctl -u droneaware-wifi -f    # live WiFi feeder log"
echo "   sudo systemctl status droneaware-ble     # service status"
echo "   cat /etc/droneaware/claim.txt            # view your claim URL again"
echo ""
