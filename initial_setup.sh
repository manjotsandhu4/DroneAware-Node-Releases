#!/bin/bash
# DroneAware BLE + WiFi Feeder Node - Initial Provisioning Script
#
# Installs all software and auto-detects the USB Bluetooth dongle's MAC address,
# writing it to config.env so the service always targets the right adapter
# regardless of hci0/hci1 index assignment after reboots.
#
# Usage:
#   sudo bash initial_setup.sh [NODE_ID] [SERVER_URL] [NODE_TOKEN] [ENROLLMENT_SECRET] [LAT] [LON] [ELEVATION_AGL_M]
#
# Examples:
#   sudo bash initial_setup.sh NJ001 https://api.droneaware.io/api 314aae16-b3b3-43b5-a824-7a468f89a400 cbb1348c-33bd-4b52-abae-24892961d862 40.457783 -74.339173 5
#   sudo bash initial_setup.sh            # uses hostname + localhost defaults (no token, no secret)
#
# The NODE_ID should be a short, unique identifier for this sensor location.
# If omitted, the Pi's hostname is used.

set -e

NODE_ID="${1:-$(hostname)}"
SERVER_URL="${2:-https://api.droneaware.io/api}"
INSTALL_DIR="/opt/droneaware"
SERVICE_USER="droneaware"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=================================================="
echo " DroneAware Sensor Node Provisioning"
echo " Node ID  : $NODE_ID"
echo " Server   : $SERVER_URL"
echo "=================================================="

# ---------------------------------------------------------------------------
# Mobile node detection
# ---------------------------------------------------------------------------
# Arg 8 can pre-set mobile mode ("yes"/"no") for scripted installs
if [[ "${8:-}" =~ ^[Yy] ]]; then
    NODE_MOBILE=true
elif [[ "${8:-}" =~ ^[Nn] ]]; then
    NODE_MOBILE=false
else
    echo ""
    echo "Will this node be used as a mobile/vehicle-mounted detection system?"
    echo "(Mobile nodes are excluded from triangulation unless a GPS module is present)"
    read -rp "  Mobile node? [y/N]: " _mobile_answer
    if [[ "$_mobile_answer" =~ ^[Yy] ]]; then
        NODE_MOBILE=true
    else
        NODE_MOBILE=false
    fi
fi

# Auto-detect GPS hardware (gpsd socket, USB GPS, or serial GPS)
NODE_HAS_GPS=false
if command -v gpspipe &>/dev/null && systemctl is-active --quiet gpsd 2>/dev/null; then
    NODE_HAS_GPS=true
    echo "  GPS: gpsd detected and running"
elif ls /dev/ttyUSB* /dev/ttyACM* /dev/serial0 2>/dev/null | head -1 | grep -q .; then
    NODE_HAS_GPS=true
    echo "  GPS: Serial/USB GPS device detected"
fi

if [[ "$NODE_MOBILE" == "true" ]]; then
    echo ""
    if [[ "$NODE_HAS_GPS" == "true" ]]; then
        echo "  Mobile node WITH GPS — live location will be used for detections."
    else
        echo "  Mobile node WITHOUT GPS — detections will be excluded from triangulation."
        echo "  Install a GPS module and gpsd to enable location-aware mobile scanning."
    fi
    echo ""
fi

# ---------------------------------------------------------------------------
# 1. System packages
# ---------------------------------------------------------------------------
echo ""
echo "[1/8] Installing system packages..."
apt-get update -qq
apt-get install -y --no-install-recommends \
    bluez bluetooth rfkill \
    libglib2.0-dev \
    iw wireless-tools \
    curl

systemctl enable bluetooth
systemctl start bluetooth

# ---------------------------------------------------------------------------
# 2. Service user
# ---------------------------------------------------------------------------
echo "[2/8] Creating service user..."
if ! id "$SERVICE_USER" &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
fi
usermod -aG bluetooth "$SERVICE_USER"

# ---------------------------------------------------------------------------
# 3. Install app files
# ---------------------------------------------------------------------------
echo "[3/8] Installing feeder binaries..."
mkdir -p "$INSTALL_DIR"

for f in ble_feeder wifi_feeder; do
    if [[ -f "$SCRIPT_DIR/$f" ]]; then
        cp "$SCRIPT_DIR/$f" "$INSTALL_DIR/$f"
        chmod +x "$INSTALL_DIR/$f"
    else
        echo "  WARNING: $f binary not found in $SCRIPT_DIR — skipping"
    fi
done

# BT adapter selector script (manages disable-bt overlay automatically)
if [[ -f "$SCRIPT_DIR/droneaware-bt-select" ]]; then
    cp "$SCRIPT_DIR/droneaware-bt-select" /usr/local/bin/droneaware-bt-select
    chmod +x /usr/local/bin/droneaware-bt-select
else
    echo "  WARNING: droneaware-bt-select not found in $SCRIPT_DIR — skipping"
fi

chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"

# ---------------------------------------------------------------------------
# 4. Auto-detect USB Bluetooth dongle MAC address
# ---------------------------------------------------------------------------
echo "[4/8] Detecting USB Bluetooth adapter..."

find_usb_bt_mac() {
    # Walk every HCI adapter in sysfs and find the one with DEVTYPE=usb_interface.
    # The Pi's built-in BT is an UART device (DRIVER=hci_uart_bcm); USB dongles
    # expose DEVTYPE=usb_interface in their uevent file.
    #
    # Returns: "hciN MAC" on success, empty string on failure.
    local hci mac uevent_path
    for hci in /sys/class/bluetooth/hci*; do
        [[ -d "$hci" ]] || continue
        uevent_path="$hci/device/uevent"
        [[ -f "$uevent_path" ]] || continue
        if grep -q "DEVTYPE=usb_interface" "$uevent_path"; then
            hci_name="$(basename "$hci")"
            # Pull BD Address from hciconfig
            mac=$(hciconfig "$hci_name" 2>/dev/null \
                  | grep -oP 'BD Address:\s+\K[0-9A-Fa-f:]{17}' | head -1)
            if [[ -n "$mac" ]]; then
                echo "$hci_name $mac"
                return 0
            fi
        fi
    done
    return 1
}

USB_BT_INFO=$(find_usb_bt_mac || true)

if [[ -z "$USB_BT_INFO" ]]; then
    echo ""
    echo "  !! No USB Bluetooth adapter detected."
    echo "  !! Make sure the USB BT dongle is plugged in, then re-run this script."
    echo "  !! Falling back to hci0 with no MAC lock — hci0/hci1 swaps may occur."
    BLE_ADAPTER_HCI="hci0"
    BLE_ADAPTER_MAC=""
else
    BLE_ADAPTER_HCI=$(echo "$USB_BT_INFO" | awk '{print $1}')
    BLE_ADAPTER_MAC=$(echo "$USB_BT_INFO" | awk '{print $2}')
    echo "  Found USB BT adapter: $BLE_ADAPTER_HCI  MAC: $BLE_ADAPTER_MAC"
fi

# ---------------------------------------------------------------------------
# 5. Detect WiFi scanner adapter + configure NetworkManager
# ---------------------------------------------------------------------------
echo "[5/7] Configuring WiFi scanner adapter..."

# Find a WiFi interface that is NOT providing the default route (i.e. not internet)
WIFI_ADAPTER=""
for iface in $(iw dev 2>/dev/null | awk '/Interface/{print $2}'); do
    if ! ip route show default 2>/dev/null | grep -q "dev $iface"; then
        WIFI_ADAPTER="$iface"
        break
    fi
done
WIFI_ADAPTER="${WIFI_ADAPTER:-wlan1}"
echo "  WiFi scanner interface: $WIFI_ADAPTER"

# Tell NetworkManager to leave the scanner interface alone so it doesn't
# fight with scapy when the feeder switches it to monitor mode
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/droneaware-unmanaged.conf <<EOF
[keyfile]
unmanaged-devices=interface-name:$WIFI_ADAPTER
EOF
systemctl reload NetworkManager 2>/dev/null || true
echo "  NetworkManager will not manage $WIFI_ADAPTER"

# ---------------------------------------------------------------------------
# 6. Write config
# ---------------------------------------------------------------------------
echo "[6/7] Writing config..."
NODE_TOKEN="${3:-}"
ENROLLMENT_SECRET="${4:-}"

cat > "$INSTALL_DIR/config.env" <<EOF
NODE_ID=$NODE_ID
SERVER_URL=$SERVER_URL
BLE_ADAPTER=$BLE_ADAPTER_HCI
BLE_ADAPTER_MAC=$BLE_ADAPTER_MAC
BATCH_SIZE=200
FLUSH_INTERVAL=5.0
NODE_TOKEN=$NODE_TOKEN
ENROLLMENT_SECRET=$ENROLLMENT_SECRET
WIFI_ADAPTER=$WIFI_ADAPTER
NODE_MOBILE=$NODE_MOBILE
NODE_HAS_GPS=$NODE_HAS_GPS
EOF
if [ -n "${5:-}" ]; then echo "NODE_LAT=$5"             >> "$INSTALL_DIR/config.env"; fi
if [ -n "${6:-}" ]; then echo "NODE_LON=$6"             >> "$INSTALL_DIR/config.env"; fi
if [ -n "${7:-}" ]; then echo "NODE_ELEVATION_AGL_M=$7" >> "$INSTALL_DIR/config.env"; fi
chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/config.env"
chmod 600 "$INSTALL_DIR/config.env"

echo "  Config written to $INSTALL_DIR/config.env"
[[ -n "$BLE_ADAPTER_MAC" ]] && \
    echo "  MAC lock: $BLE_ADAPTER_MAC (immune to hci0/hci1 index swaps)"

# ---------------------------------------------------------------------------
# 7. systemd services
# ---------------------------------------------------------------------------
echo "[7/7] Installing systemd services..."

# Build the --adapter-mac flag conditionally
ADAPTER_MAC_FLAG=""
[[ -n "$BLE_ADAPTER_MAC" ]] && ADAPTER_MAC_FLAG="    --adapter-mac \${BLE_ADAPTER_MAC} \\"

# BT adapter selector service (auto-manages disable-bt overlay on each boot)
cat > /etc/systemd/system/droneaware-bt-select.service <<EOF
[Unit]
Description=DroneAware BT Adapter Selector
After=bluetooth.service
Before=droneaware-ble.service droneaware-wifi.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/droneaware-bt-select

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/droneaware-ble.service <<EOF
[Unit]
Description=DroneAware BLE Remote ID Feeder
After=network-online.target bluetooth.target droneaware-bt-select.service
Wants=network-online.target

[Service]
Type=simple
User=root
EnvironmentFile=$INSTALL_DIR/config.env
ExecStartPre=/usr/sbin/rfkill unblock bluetooth
ExecStart=$INSTALL_DIR/ble_feeder \\
    --node-id \${NODE_ID} \\
    --server \${SERVER_URL} \\
    --adapter \${BLE_ADAPTER} \\
${ADAPTER_MAC_FLAG}
    --batch-size \${BATCH_SIZE} \\
    --flush-interval \${FLUSH_INTERVAL}
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=droneaware-ble

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/droneaware-wifi.service <<EOF
[Unit]
Description=DroneAware WiFi Remote ID Feeder
After=network-online.target droneaware-bt-select.service
Wants=network-online.target

[Service]
Type=simple
User=root
EnvironmentFile=$INSTALL_DIR/config.env
ExecStart=$INSTALL_DIR/wifi_feeder \\
    --iface \${WIFI_ADAPTER} \\
    --node-id \${NODE_ID} \\
    --server \${SERVER_URL} \\
    --batch-size \${BATCH_SIZE} \\
    --flush-interval \${FLUSH_INTERVAL}
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=droneaware-wifi

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable droneaware-bt-select
systemctl enable droneaware-ble
# WiFi service: enable only if a monitor-capable adapter is detected
if iw dev 2>/dev/null | grep -q Interface; then
    echo "  WiFi adapter detected — enabling droneaware-wifi service"
    systemctl enable droneaware-wifi
else
    echo "  No WiFi adapter found — droneaware-wifi service installed but not enabled"
fi

# ---------------------------------------------------------------------------
# 7. Summary
# ---------------------------------------------------------------------------
echo ""
echo "[8/8] Adapter inventory:"
hciconfig -a 2>/dev/null | grep -E '(hci[0-9]+:|BD Address)' || echo "  (none found)"
echo ""
echo "=================================================="
echo " Provisioning complete!"
echo ""
echo " Node ID      : $NODE_ID"
echo " Server       : $SERVER_URL"
echo " WiFi scanner : $WIFI_ADAPTER  (NM unmanaged)"
if [[ -n "$BLE_ADAPTER_MAC" ]]; then
echo " BLE MAC      : $BLE_ADAPTER_MAC  (locked — survives reboots)"
else
echo " BLE MAC      : NOT SET — plug in USB dongle and re-run to lock"
fi
if [[ "$NODE_MOBILE" == "true" ]]; then
echo " Mode         : MOBILE  (GPS: $NODE_HAS_GPS)"
else
echo " Mode         : FIXED"
fi
echo ""
echo " Commands:"
echo "   sudo systemctl start droneaware-ble       # start BLE feeder"
echo "   sudo systemctl status droneaware-ble      # check status"
echo "   sudo journalctl -u droneaware-ble -f      # live BLE log"
echo "   sudo journalctl -u droneaware-wifi -f     # live WiFi log"
echo ""
echo " To update config later:"
echo "   sudo nano $INSTALL_DIR/config.env"
echo "   sudo systemctl restart droneaware-ble droneaware-wifi"
echo "=================================================="
