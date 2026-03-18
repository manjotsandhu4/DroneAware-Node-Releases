# DroneAware Node — Setup Guide

**Turn a Raspberry Pi into a live drone detection sensor in under 10 minutes.**

DroneAware nodes listen for FAA-mandated Remote ID broadcasts from drones flying in your area and forward them to the DroneAware network, where they appear on a live map at [droneaware.io](https://droneaware.io).

---

## What You Need

| Item | Notes |
|---|---|
| Raspberry Pi 4 (1 GB or more) | 2 GB+ recommended if running other software |
| MicroSD card (16 GB+, Class 10) | Samsung Endurance or SanDisk High Endurance preferred |
| USB Bluetooth adapter | **Sena UD100** or any CSR/Cambridge Silicon Radio USB dongle |
| WiFi adapter (optional, recommended) | **Alfa AWUS036N** (Ralink RT3070 chipset, 2.4 GHz) |
| 5V/3A USB-C power supply | Official Raspberry Pi PSU recommended |
| Ethernet cable or WiFi credentials | For initial setup |

> **Why a USB Bluetooth adapter?**
> The Pi's built-in Bluetooth works, but its antenna is inside the case. A USB dongle with an external antenna has significantly better range. The Sena UD100 / CSR chipset is confirmed working and widely available for under $20.

> **Why the Alfa WiFi adapter?**
> The Alfa AWUS036N supports monitor mode, which is required to capture Wi-Fi Remote ID beacon frames (the 802.11 transport used by many newer drones). The Pi's built-in WiFi cannot be put into monitor mode reliably.

---

## Quick Start

### Step 1 — Flash the SD Card

1. Download **[Raspberry Pi Imager](https://www.raspberrypi.com/software/)** on your computer.
2. Click **Choose OS → Raspberry Pi OS (other) → Raspberry Pi OS Lite (64-bit)**.
3. Click the **gear icon** (Advanced Options) and configure:
   - Set hostname: e.g. `droneaware-node`
   - Enable SSH, set a username/password (remember these)
   - **Optional but recommended:** enter your WiFi network name and password here — this avoids needing an Ethernet cable
4. Select your SD card and click **Write**.

### Step 2 — Boot the Pi

1. Insert the SD card, plug in your USB Bluetooth adapter, connect power.
2. Wait 60–90 seconds for the Pi to boot.
3. Find the Pi's IP address:
   - Check your router's device list, or
   - If you set a hostname, try `ssh droneaware-node.local` (or whatever hostname you chose)
4. SSH into the Pi:
   ```
   ssh <your-username>@<pi-ip-address>
   ```
   Then switch to root:
   ```
   sudo -i
   ```

### Step 3 — Install DroneAware

Run this single command:

```bash
curl -fsSL https://droneaware.io/install | sudo bash
```

This downloads all the DroneAware software and takes about 2 minutes.

When it finishes, run the setup wizard:

```bash
sudo droneaware-setup
```

### Step 4 — Follow the Setup Wizard

The wizard will ask you five things:

1. **Internet check** — confirms the Pi can reach the DroneAware servers.

2. **Node ID** — a short unique name for your sensor (e.g. `DA-B1C7`).
   The wizard auto-generates one from your Bluetooth adapter's MAC address.
   You can accept the suggestion or type your own.

3. **Location** — the GPS coordinates and mounting height of your antenna.

   **How to find your coordinates:**
   - **Google Maps**: right-click exactly where your antenna is located → the coordinates appear at the top of the popup. Click them to copy.
   - **iPhone Maps**: tap and hold on the map at your antenna location → coordinates appear at the top of the screen.
   - **Google Earth**: hover your cursor over the antenna location and read from the bottom status bar.

   **Elevation above ground** is how high the antenna is mounted above the surface directly below it — *not* altitude above sea level.
   - Ground-floor window: ~2 m
   - Second-floor window or flat rooftop: ~5–8 m
   - Rooftop antenna mast: 10–15 m

4. **Software install** — runs automatically, no input needed (~3 minutes).

5. **Node registration** — your node contacts the DroneAware server, gets a token, and receives a **claim link**.

### Step 5 — Claim Your Node

At the end of setup, the wizard displays something like:

```
╔══════════════════════════════════════════════════════════════╗
║  Your node is enrolled! Link it to your account below.       ║
║                                                              ║
║  Claim URL:  https://droneaware.io/claim/DA-B1C7?code=XXXX  ║
║  Code:       XXXX-YYYY                                       ║
║                                                              ║
║  This link expires in 48 hours.                              ║
║  Saved to: /etc/droneaware/claim.txt                         ║
╚══════════════════════════════════════════════════════════════╝
```

Open the claim URL in a browser, create a free account (or log in), and link the node to your account. This gives you:

- Your node on the live map
- Detection history and alerts
- The ability to manage your node remotely

> If you miss the 48-hour window, contact support at droneaware.io to reset your claim code.
> You can also view the URL again any time: `cat /etc/droneaware/claim.txt`

---

## What Happens After Setup

Both feeder services start automatically at boot and restart themselves if they crash:

| Service | What it does |
|---|---|
| `droneaware-ble` | Scans for Bluetooth Remote ID broadcasts (ASTM F3411 over BLE) |
| `droneaware-wifi` | Captures Wi-Fi Remote ID beacon frames (requires Alfa adapter) |

Every detection is forwarded to the DroneAware server in real time. Every 60 seconds, the node sends a heartbeat so the dashboard shows it as online.

---

## Useful Commands

```bash
# Check if the BLE feeder is running
sudo systemctl status droneaware-ble

# Watch live detection log
sudo journalctl -u droneaware-ble -f

# Watch live WiFi feeder log
sudo journalctl -u droneaware-wifi -f

# View your claim URL
cat /etc/droneaware/claim.txt

# Edit node config (location, server URL, etc.)
sudo nano /opt/droneaware/config.env
sudo systemctl restart droneaware-ble

# Re-run setup wizard (e.g. after hardware change)
sudo rm /opt/droneaware/.configured
sudo droneaware-setup
```

---

## Troubleshooting

**The wizard says "No USB Bluetooth adapter detected"**
Make sure the USB dongle is plugged in before running `droneaware-setup`. Unplug and replug it, then run `hciconfig -a` to confirm the Pi sees it.

**"No internet connection detected"**
- If using Ethernet: check the cable and that your router assigned an IP (`ip addr show eth0`).
- If using WiFi: verify your credentials in `/boot/wpa_supplicant.conf`, then reboot.

**The BLE feeder starts but shows 0 detections**
This is normal — there may simply be no drones broadcasting Remote ID nearby. Remote ID is only required for drones registered after September 2023 and most recreational fliers. Detection depends on local drone activity.

**I need to change my node's location**
Edit `/opt/droneaware/config.env` and update `NODE_LAT`, `NODE_LON`, and `NODE_ELEVATION_AGL_M`. Then restart the services:
```bash
sudo systemctl restart droneaware-ble droneaware-wifi
```
Contact support to update the location on the server side as well.

**The feeder service keeps restarting**
```bash
sudo journalctl -u droneaware-ble -n 50
```
Look for error messages. Common causes: Bluetooth adapter not found (`--adapter-mac` mismatch), Python dependency missing, or the server is unreachable.

**I lost my claim URL**
```bash
cat /etc/droneaware/claim.txt
```
If the file is gone and the 48-hour window has passed, contact support.

---

## Node File Locations

| File | Purpose |
|---|---|
| `/opt/droneaware/config.env` | Main configuration (node ID, location, token) |
| `/opt/droneaware/ble_feeder.py` | BLE Remote ID capture script |
| `/opt/droneaware/wifi_feeder.py` | WiFi Remote ID capture script |
| `/etc/droneaware/token` | Node auth token (written at enrollment) |
| `/etc/droneaware/claim.txt` | Claim URL and code from enrollment |
| `/opt/droneaware/.configured` | Sentinel file — delete this to re-run setup wizard |
| `/var/log/droneaware_wifi.log` | WiFi feeder log file |

---

## Privacy

DroneAware captures and forwards **only data broadcast publicly by the drones themselves** via FAA-mandated Remote ID transmissions. Remote ID is an open broadcast — equivalent to a drone's tail number. No private communications, networks, or devices are accessed. Your node's location coordinates are stored on the DroneAware server to correctly place detections on the map.

---

## Support

- Website: [droneaware.io](https://droneaware.io)
- GitHub: [github.com/droneaware-io/node](https://github.com/droneaware-io/node)

---

*Copyright (c) 2026 DroneAware, LLC. Use of this software is subject to the terms of the DroneAware Feeder Node Software License. See [LICENSE](LICENSE) for details.*
