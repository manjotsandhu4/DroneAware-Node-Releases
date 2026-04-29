# DroneAware Node - Ubuntu/Desktop Setup Guide

## Quick Start for Dell Latitude 7389 (Ubuntu)

Your laptop is fully compatible! You have two options:

### Option 1: Use Built-in Adapters (Quick Test)
The built-in Intel Bluetooth and WiFi will work for basic BLE detection.

```bash
cd /workspace
sudo bash install-ubuntu.sh
```

### Option 2: Use External Adapters (Recommended for Best Performance)
For maximum range and full functionality with external USB Bluetooth, WiFi, and RTL-SDR adapters:

```bash
cd /workspace
sudo bash install-ubuntu-latitude.sh
```

See [LATITUDE_SETUP.md](LATITUDE_SETUP.md) for complete external adapter setup guide.

**Recommended Hardware:**
- **USB Bluetooth**: Sena UD100 (CSR chipset) - $15
- **USB WiFi**: Alfa AWUS036N (RT3070 chipset) - $25  
- **RTL-SDR**: RTL-SDR Blog v3 or similar - $25

The RTL-SDR v3 adds support for capturing drone telemetry on LoRa (433/868/915 MHz), ADS-B (1090 MHz), and other sub-2.4 GHz frequencies that WiFi/BLE cannot receive.

## Manual Installation

If you prefer manual control or want to test before committing:

#### 1. Install System Dependencies

```bash
sudo apt update
sudo apt install -y python3-pip python3-venv bluez bluez-tools \
    libbluetooth-dev iw rfkill curl tcpdump net-tools
```

#### 2. Create Virtual Environment

```bash
cd /workspace
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install bleak requests pyrtlsdr
```

#### 2b. Install RTL-SDR System Dependencies (Optional)

If using an RTL-SDR dongle:

```bash
sudo apt install -y rtl-sdr librtlsdr-dev
```

#### 3. Test Bluetooth Detection (No Installation Required)

```bash
# Ensure Bluetooth is running
sudo systemctl start bluetooth

# Check your Bluetooth adapter
hciconfig -a

# Run the BLE feeder in test mode (verbose output)
sudo source venv/bin/activate && sudo python3 ble_feeder.py --verbose
```

You should see BLE advertisements appearing if there are any Remote ID-enabled drones nearby.

#### 4. Run Without Cloud Enrollment (Local Testing Only)

For testing without enrolling on droneaware.io:

```bash
# Create a dummy token file
sudo mkdir -p /etc/droneaware
echo "test-token" | sudo tee /etc/droneaware/token

# Run with local server
sudo python3 ble_feeder.py --server http://localhost:8000/api --verbose
```

Or run completely standalone (no server):

```bash
# Just watch for packets locally
sudo python3 -c "
import asyncio
from bleak import BleakScanner

async def scan():
    def callback(device, adv):
        if 'fffa' in str(adv.service_data).lower():
            print(f'Drone detected: {device.address} RSSI:{adv.rssi}')
    
    scanner = BleakScanner(callback, service_uuids=['0000fffa-0000-1000-8000-00805f9b34fb'])
    await scanner.start()
    await asyncio.sleep(60)
    await scanner.stop()

asyncio.run(scan())
"
```

## Hardware Notes for Dell Latitude 7389

### Built-in Adapters
- **Bluetooth**: Intel Wireless-AC 8265 (includes BT 4.2) ✓ Works great for BLE
- **WiFi**: Intel Dual Band Wireless-AC 8265 ⚠️ Limited monitor mode support

### Expected Performance
- **BLE Range**: 50-100 feet indoors, up to 300 feet outdoors (depends on drone)
- **WiFi Range**: Limited - internal cards often can't enter proper monitor mode

### Recommended Upgrade (Optional)
For maximum range and WiFi capture capability:
- **USB Bluetooth**: Sena UD100 (CSR chipset) - $15
- **USB WiFi**: Alfa AWUS036N (RT3070 chipset) - $25

These plug into your laptop's USB ports and dramatically improve detection range.

## Configuration Options

### Static vs Mobile Mode

**Static** (default for home/office):
- Enter fixed GPS coordinates once
- All detections use this location

**Mobile** (for vehicle/portable use):
- Requires USB GPS dongle (e.g., u-blox 7/8)
- Location updates automatically from GPS

### Service Management

After installation:

```bash
# Start services
sudo systemctl start droneaware-ble
sudo systemctl start droneaware-wifi
sudo systemctl start droneaware-sdr

# Enable auto-start on boot
sudo systemctl enable droneaware-ble
sudo systemctl enable droneaware-wifi
sudo systemctl enable droneaware-sdr

# View logs
journalctl -u droneaware-ble -f
journalctl -u droneaware-wifi -f
journalctl -u droneaware-sdr -f

# Stop services
sudo systemctl stop droneaware-ble
sudo systemctl stop droneaware-wifi
sudo systemctl stop droneaware-sdr
```

## Local Network Broadcasting

DroneAware broadcasts detections via UDP to your local network:
- **Port**: 9999
- **Address**: 255.255.255.255 (broadcast)
- **Format**: JSON lines

Listen on another device:
```bash
nc -ul 9999
```

Or view the local buffer:
```bash
cat /run/droneaware/detections.jsonl
```

## Troubleshooting

### Bluetooth Not Working
```bash
# Check Bluetooth status
systemctl status bluetooth

# Restart Bluetooth
sudo systemctl restart bluetooth

# List adapters
hciconfig -a

# Bring adapter up
sudo hciconfig hci0 up
```

### Permission Denied Errors
```bash
# Give Python capabilities for raw sockets
sudo setcap 'cap_net_raw,cap_net_admin+eip' $(which python3)
```

### No Drones Detected
- Remote ID drones are still relatively rare (FAA mandate phased in through 2024)
- Move near airports, drone flying fields, or large events
- BLE range is limited - try moving outdoors or near a window
- Check that no other Bluetooth apps are interfering

### WiFi Monitor Mode Issues
Most internal laptop WiFi cards don't support monitor mode well. To check:

```bash
# Put interface in monitor mode (replace wlan0 with your interface)
sudo ip link set wlan0 down
sudo iw wlan0 set monitor control
sudo ip link set wlan0 up

# Check for errors
iwconfig wlan0
```

If this fails, you need an external USB adapter (Alfa AWUS036N recommended).

## Use Cases for Laptop Deployment

1. **Portable Detection Station**: Carry your laptop to events, parks, or areas of interest
2. **Home Office Monitoring**: Run continuously at your desk to monitor airspace
3. **Development & Testing**: Test new features without flashing SD cards
4. **Multi-Node Network**: Run multiple instances (with multiple adapters) for directional detection
5. **Vehicle-Mounted**: Add USB GPS for mobile mapping of drone activity

## Next Steps

1. Run `sudo bash install-ubuntu.sh` to get started
2. Enroll your node at https://droneaware.io/nodes
3. View your detections on the live map
4. Consider adding external adapters for better range

For questions or issues, check the main README.md or open an issue on GitHub.
