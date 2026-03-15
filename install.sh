#!/bin/bash
# DroneAware BLE Feeder - Raspberry Pi Setup Script
# Run this once on a fresh Pi OS Lite (64-bit recommended)
# Usage: sudo bash install.sh [NODE_ID] [SERVER_URL]

set -e

NODE_ID="${1:-droneaware-node}"
SERVER_URL="${2:-http://your-server:8000}"
INSTALL_DIR="/opt/droneaware"
SERVICE_USER="droneaware"

echo "=================================================="
echo " DroneAware BLE Feeder Node Setup"
echo " Node ID  : $NODE_ID"
echo " Server   : $SERVER_URL"
echo "=================================================="

# -- System packages -----------------------------------------------------------
echo "[1/6] Installing system packages..."
apt-get update -qq
apt-get install -y --no-install-recommends \
    python3 python3-pip python3-venv \
    bluez bluetooth \
    libglib2.0-dev \
    git curl

# Ensure Bluetooth service is up
systemctl enable bluetooth
systemctl start bluetooth

# -- Create service user -------------------------------------------------------
echo "[2/6] Creating service user..."
if ! id "$SERVICE_USER" &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
fi

# Add to bluetooth group so it can access BLE hardware
usermod -aG bluetooth "$SERVICE_USER"

# -- Install app ---------------------------------------------------------------
echo "[3/6] Installing feeder software..."
mkdir -p "$INSTALL_DIR"
cp ble_feeder.py "$INSTALL_DIR/"

# Python venv
python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install --quiet --upgrade pip
"$INSTALL_DIR/venv/bin/pip" install --quiet bleak requests

chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"

# -- Config file ---------------------------------------------------------------
echo "[4/6] Writing config..."
cat > "$INSTALL_DIR/config.env" <<EOF
NODE_ID=$NODE_ID
SERVER_URL=$SERVER_URL
BATCH_SIZE=10
FLUSH_INTERVAL=2.0
EOF
chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/config.env"
chmod 600 "$INSTALL_DIR/config.env"

# -- systemd service -----------------------------------------------------------
echo "[5/6] Installing systemd service..."
cat > /etc/systemd/system/droneaware-ble.service <<EOF
[Unit]
Description=DroneAware BLE Remote ID Feeder
After=network-online.target bluetooth.target
Wants=network-online.target

[Service]
Type=simple
User=root
EnvironmentFile=$INSTALL_DIR/config.env
ExecStart=$INSTALL_DIR/venv/bin/python3 $INSTALL_DIR/ble_feeder.py \
    --node-id \${NODE_ID} \
    --server \${SERVER_URL} \
    --batch-size \${BATCH_SIZE} \
    --flush-interval \${FLUSH_INTERVAL}
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=droneaware-ble

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable droneaware-ble

# -- BLE adapter check ---------------------------------------------------------
echo "[6/6] Checking Bluetooth adapters..."
hciconfig -a || echo "  (no adapters found yet - plug in UD100 and reboot)"

echo ""
echo "=================================================="
echo " Installation complete!"
echo ""
echo " Commands:"
echo "   sudo systemctl start droneaware-ble    # start"
echo "   sudo systemctl status droneaware-ble   # status"
echo "   sudo journalctl -u droneaware-ble -f   # live logs"
echo ""
echo " To change server URL later:"
echo "   sudo nano $INSTALL_DIR/config.env"
echo "   sudo systemctl restart droneaware-ble"
echo "=================================================="
