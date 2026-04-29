# RTL-SDR v3 Integration Summary

## Changes Made for Dell Latitude 7389 with WiFi, Bluetooth, and RTL-SDR v3

### New Files Created

1. **`sdr_feeder.py`** - New RTL-SDR feeder script
   - Captures RF signals on configurable frequencies (433.92, 868, 915, 1090, 1575.42 MHz)
   - Supports LoRa drone telemetry, ADS-B, and other sub-2.4 GHz protocols
   - Uses pyrtlsdr library for SDR control
   - Maintains same API contract as wifi_feeder.py and ble_feeder.py
   - Includes frequency sweeper, signal detection, and Remote ID decoding

2. **`droneaware-sdr.service`** - Systemd service for RTL-SDR feeder
   - Auto-starts at boot
   - Restarts on failure
   - Logs to journalctl under "droneaware-sdr"

### Modified Files

1. **`install-ubuntu.sh`**
   - Added `rtl-sdr` and `librtlsdr-dev` to system packages (line 309)
   - Added `pyrtlsdr` to Python dependencies (line 332)
   - Added `sdr_feeder.py` to script installation (line 346)
   - Created systemd service for SDR feeder (lines 405-425)
   - Enabled `droneaware-sdr` service (line 428)
   - Added config variables `FREQ_DWELL` and `SDR_GAIN` (lines 458-459)

2. **`UBUNTU_SETUP.md`**
   - Updated hardware recommendations to include RTL-SDR Blog v3
   - Added RTL-SDR system dependencies installation step
   - Updated pip install command to include pyrtlsdr
   - Added droneaware-sdr service management commands

### Architecture

Your Dell Latitude 7389 now runs **three parallel detection services**:

```
┌─────────────────────────────────────────────────────────────┐
│                  Dell Latitude 7389                         │
│                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │ BLE Feeder   │  │ WiFi Feeder  │  │ SDR Feeder   │      │
│  │ (Bluetooth)  │  │ (2.4 GHz)    │  │ (24-1766 MHz)│      │
│  │              │  │              │  │              │      │
│  │ • ASTM F3411 │  │ • ASTM F3411 │  │ • LoRa       │      │
│  │ • UUID 0xFFFA│  │ • Beacon IE  │  │ • ADS-B      │      │
│  │ • 2.4 GHz    │  │ • NAN frames │  │ • 433/915 MHz│      │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘      │
│         │                 │                 │               │
│         └────────────┬────┴────────────────┘               │
│                      │                                      │
│              ┌───────▼────────┐                            │
│              │ Forwarder      │                            │
│              │ (batch/flush)  │                            │
│              └───────┬────────┘                            │
│                      │                                      │
│              ┌───────▼────────┐                            │
│              │ Local Publisher│                            │
│              │ • JSONL buffer │                            │
│              │ • UDP broadcast│                            │
│              └───────┬────────┘                            │
│                      │                                      │
└──────────────────────┼──────────────────────────────────────┘
                       │
                       ▼
            ┌──────────────────┐
            │ DroneAware Cloud │
            │ api.droneaware.io│
            └──────────────────┘
```

### Frequency Coverage

| Service | Frequency Range | Protocols Supported |
|---------|----------------|---------------------|
| **BLE** | 2.402-2.480 GHz | ASTM F3411 BLE (UUID 0xFFFA) |
| **WiFi** | 2.412-2.462 GHz (Ch 1-11) | ASTM F3411 WiFi Beacon, NAN |
| **SDR** | 24-1766 MHz (configurable) | LoRa (433/868/915), ADS-B (1090), proprietary links |

> **Note:** ASTM F3411 Remote ID primarily uses BLE and WiFi at 2.4 GHz. The RTL-SDR captures other drone telemetry protocols that operate on lower frequencies.

### Configuration

Edit `/opt/droneaware/config.env` to customize SDR behavior:

```bash
FREQ_DWELL=0.5        # Seconds per frequency (default: 0.5)
SDR_GAIN=auto         # LNA gain: 'auto' or 0-49.6 dB
```

Custom frequencies can be specified when running manually:
```bash
sudo python3 sdr_feeder.py --frequencies 433.92 915.0 1090.0
```

### Installation Commands

```bash
# Install system dependencies
sudo apt update
sudo apt install -y rtl-sdr librtlsdr-dev

# Install Python dependency
pip3 install pyrtlsdr

# Or run the full installer
cd /workspace
sudo bash install-ubuntu.sh
```

### Service Management

```bash
# Start all services
sudo systemctl start droneaware-ble
sudo systemctl start droneaware-wifi
sudo systemctl start droneaware-sdr

# View SDR logs
journalctl -u droneaware-sdr -f

# Check status
systemctl status droneaware-sdr
```

### Testing Without Installation

```bash
# Create virtual environment
cd /workspace
python3 -m venv venv
source venv/bin/activate
pip install pyrtlsdr requests

# Run SDR feeder in verbose mode
sudo python3 sdr_feeder.py --verbose --frequencies 433.92 915.0
```

### Hardware Notes for Dell Latitude 7389

- **Built-in Intel WiFi/BT**: Works for BLE detection, limited WiFi monitor mode
- **USB Ports**: Use USB 3.0 ports for RTL-SDR v3 (better bandwidth)
- **RTL-SDR v3**: Plug into any USB port, no external power needed
- **Antenna**: Use included dipole antenna; upgrade to magnetic mount for better range

### Expected Performance

- **BLE**: 50-300 feet (depends on obstacles)
- **WiFi**: 100-500 feet with Alfa AWUS036N adapter
- **SDR**: Varies by frequency and modulation
  - LoRa: Up to several miles with good antenna
  - ADS-B: 100+ miles for aircraft at altitude

### Troubleshooting

**RTL-SDR not detected:**
```bash
# Check if device is recognized
lsusb | grep RTL

# Test with rtl_test
rtl_test -t
```

**Permission denied:**
```bash
# Add udev rule
echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="0bda", ATTR{idProduct}=="2838", MODE="0666"' | \
  sudo tee /etc/udev/rules.d/20-rtl-sdr.rules
sudo udevadm control --reload-rules
```

**No signals detected:**
- Verify antenna is connected
- Try increasing gain: `--gain 49.6`
- Check for interference from laptop USB 3.0 (use extension cable)
- Move near known drone activity areas

### Next Steps

1. Run `sudo bash install-ubuntu.sh` to install all components
2. Enroll your node at https://droneaware.io/nodes
3. Connect RTL-SDR v3 to USB port
4. Monitor logs: `journalctl -u droneaware-sdr -f`
5. Adjust frequencies based on local drone activity
