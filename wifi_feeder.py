#!/usr/bin/env python3
"""
DroneAware WiFi Feeder - Remote ID Capture Script
Hardware: Raspberry Pi 4 + Alfa AWUS036N (RT3070, 2.4 GHz)
Captures WiFi Remote ID in 802.11 Beacon frames (ASTM F3411) and forwards to
the DroneAware server.

Supports:
  - Wi-Fi Beacon transport (vendor IE, OUI FA:0B:BC, type 0x0D)  [F3411-19/22a]
  - Wi-Fi NAN transport detection (action frames, OUI 50:6F:9A)  [F3411-22a]

Usage:
    sudo python3 wifi_feeder.py --iface wlan1 --node-id NJ001 --server http://server/api

Requirements:
    pip3 install scapy requests
    sudo apt install iw wireless-tools
"""

import threading
import subprocess
import time
import struct
import logging
import argparse
import socket
import os
import requests
from scapy.all import sniff, Dot11, Dot11Beacon, Dot11Elt, RadioTap, Dot11Action

# -- Logging -------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler("/var/log/droneaware_wifi.log"),
    ],
)
log = logging.getLogger("droneaware.wifi")

# -- Constants -----------------------------------------------------------------

# Vendor-specific IE OUI for ASTM F3411 Wi-Fi Beacon transport
ASTM_OUI     = bytes([0xFA, 0x0B, 0xBC])
ASTM_OUI_TYPE = 0x0D  # Remote ID app code

# Wi-Fi Alliance NAN OUI (action frames)
NAN_OUI      = bytes([0x50, 0x6F, 0x9A])
NAN_OUI_TYPE = 0x13  # NAN

# 2.4 GHz channels (RT3070 is 2.4 GHz only)
CHANNELS_24 = list(range(1, 12))  # 1-11 (US band)

MSG_TYPE = {
    0x0: "Basic ID",
    0x1: "Location/Vector",
    0x2: "Authentication",
    0x3: "Self ID",
    0x4: "System",
    0x5: "Operator ID",
    0xF: "Message Pack",
}

ID_TYPE = {
    0: "None",
    1: "Serial Number (ANSI/CTA-2063-A)",
    2: "CAA Assigned",
    3: "UTM Assigned",
    4: "Specific Session ID",
}

UA_TYPE = {
    0: "None",
    1: "Aeroplane",
    2: "Helicopter/Multirotor",
    3: "Gyroplane",
    4: "Hybrid Lift",
    5: "Ornithopter",
    6: "Glider",
    7: "Kite",
    8: "Free Balloon",
    9: "Captive Balloon",
    10: "Airship",
    11: "Free Fall/Parachute",
    12: "Rocket",
    13: "Tethered Powered Aircraft",
    14: "Ground Obstacle",
    255: "Other",
}


# -- Remote ID Decoder ---------------------------------------------------------
# (mirrors ble_feeder.py — pure functions, no shared state)

def parse_basic_id(data: bytes) -> dict:
    if len(data) < 25:
        return {}
    id_type = (data[1] >> 4) & 0x0F
    ua_type = data[1] & 0x0F
    uas_id  = data[2:22].rstrip(b'\x00').decode('ascii', errors='replace')
    return {
        "id_type": ID_TYPE.get(id_type, f"Unknown({id_type})"),
        "ua_type": UA_TYPE.get(ua_type, f"Unknown({ua_type})"),
        "uas_id":  uas_id,
    }


def parse_location(data: bytes) -> dict:
    if len(data) < 25:
        return {}
    speed_mult  = data[1] & 0x01
    height_type = (data[1] >> 2) & 0x01
    lat = struct.unpack_from('<i', data, 2)[0] * 1e-7
    lon = struct.unpack_from('<i', data, 6)[0] * 1e-7
    alt_geodetic = struct.unpack_from('<H', data, 12)[0] * 0.5 - 1000.0
    height       = struct.unpack_from('<H', data, 14)[0] * 0.5 - 1000.0
    speed        = data[16] * (0.75 if speed_mult else 0.25)
    vspeed       = data[17] * 0.5 - 62.0
    heading      = struct.unpack_from('<H', data, 18)[0] * 0.01
    return {
        "latitude":       round(lat, 7),
        "longitude":      round(lon, 7),
        "altitude_geo":   round(alt_geodetic, 1),
        "height_agl":     round(height, 1),
        "ground_speed":   round(speed, 2),
        "vertical_speed": round(vspeed, 2),
        "heading":        round(heading, 1),
        "height_type":    "AGL" if height_type == 0 else "Above Takeoff",
    }


def parse_system_msg(data: bytes) -> dict:
    if len(data) < 16:
        return {}
    op_lat      = struct.unpack_from('<i', data, 4)[0] * 1e-7
    op_lon      = struct.unpack_from('<i', data, 8)[0] * 1e-7
    area_count  = data[12]
    area_radius = data[13] * 10
    alt_takeoff = struct.unpack_from('<H', data, 14)[0] * 0.5 - 1000.0
    return {
        "operator_lat":    round(op_lat, 7),
        "operator_lon":    round(op_lon, 7),
        "area_count":      area_count,
        "area_radius_m":   area_radius,
        "alt_takeoff_geo": round(alt_takeoff, 1),
    }


def parse_operator_id(data: bytes) -> dict:
    if len(data) < 22:
        return {}
    return {
        "operator_id_type": data[1],
        "operator_id":      data[2:22].rstrip(b'\x00').decode('ascii', errors='replace'),
    }


def parse_message_pack(data: bytes) -> list:
    if len(data) < 3:
        return []
    msg_size  = data[1]
    msg_count = data[2]
    messages  = []
    for i in range(msg_count):
        offset = 3 + i * msg_size
        if offset + msg_size > len(data):
            break
        messages.append(data[offset: offset + msg_size])
    return messages


def decode_rid_message(raw_bytes: bytes) -> dict | None:
    if len(raw_bytes) < 2:
        return None
    msg_type  = (raw_bytes[0] >> 4) & 0x0F
    type_name = MSG_TYPE.get(msg_type, f"Unknown(0x{msg_type:X})")
    result    = {"message_type": type_name, "raw_hex": raw_bytes.hex().upper()}
    if msg_type == 0x0:
        result.update(parse_basic_id(raw_bytes))
    elif msg_type == 0x1:
        result.update(parse_location(raw_bytes))
    elif msg_type == 0x4:
        result.update(parse_system_msg(raw_bytes))
    elif msg_type == 0x5:
        result.update(parse_operator_id(raw_bytes))
    elif msg_type == 0xF:
        sub_msgs = parse_message_pack(raw_bytes)
        result["messages"] = [m for m in (decode_rid_message(s) for s in sub_msgs) if m]
    return result


# -- WiFi Frame Parsers --------------------------------------------------------

def get_rssi(pkt) -> int | None:
    """Extract RSSI (dBm) from RadioTap header."""
    try:
        return pkt[RadioTap].dBm_AntSignal
    except Exception:
        return None


def extract_beacon_rid(pkt) -> bytes | None:
    """
    Walk 802.11 beacon IEs looking for vendor-specific Remote ID payload.

    Beacon vendor IE structure (after scapy strips tag+length):
      Bytes 0-2: OUI  (FA:0B:BC)
      Byte  3:   OUI Type (0x0D)
      Bytes 4+:  25-byte RID message
    """
    if not pkt.haslayer(Dot11Beacon):
        return None

    elt = pkt.getlayer(Dot11Elt)
    while elt is not None:
        if elt.ID == 221:  # Vendor Specific
            data = bytes(elt.info)
            if len(data) >= 29 and data[:3] == ASTM_OUI and data[3] == ASTM_OUI_TYPE:
                return data[4:29]  # exactly 25 bytes
        # Traverse the IE linked list
        elt = elt.payload.getlayer(Dot11Elt) if elt.payload else None

    return None


def is_nan_action(pkt) -> bool:
    """
    Detect Wi-Fi NAN action frames (OUI 50:6F:9A, type 0x13).
    Full NAN RID parsing is a future enhancement — we log and capture raw for now.
    """
    if not (pkt.haslayer(Dot11) and pkt[Dot11].type == 0 and pkt[Dot11].subtype == 13):
        return False
    try:
        body = bytes(pkt[Dot11].payload)
        # Category 4 = Public Action; OUI check at offset 2
        return (len(body) >= 6 and body[0] == 4 and body[2:5] == NAN_OUI
                and body[5] == NAN_OUI_TYPE)
    except Exception:
        return False


# -- Monitor Mode --------------------------------------------------------------

def set_monitor_mode(iface: str):
    """Bring interface up in monitor mode."""
    log.info(f"Setting {iface} to monitor mode...")
    subprocess.run(["ip", "link", "set", iface, "down"],  check=True)
    subprocess.run(["iw", "dev", iface, "set", "type", "monitor"], check=True)
    subprocess.run(["ip", "link", "set", iface, "up"],   check=True)
    log.info(f"{iface} is now in monitor mode")


def restore_managed_mode(iface: str):
    """Restore interface to managed mode on exit."""
    log.info(f"Restoring {iface} to managed mode...")
    try:
        subprocess.run(["ip", "link", "set", iface, "down"],    check=False)
        subprocess.run(["iw", "dev", iface, "set", "type", "managed"], check=False)
        subprocess.run(["ip", "link", "set", iface, "up"],     check=False)
    except Exception as e:
        log.warning(f"Could not restore managed mode: {e}")


def set_channel(iface: str, channel: int):
    """Set the monitor interface to a specific 2.4 GHz channel."""
    subprocess.run(
        ["iw", "dev", iface, "set", "channel", str(channel)],
        check=False, capture_output=True,
    )


# -- Channel Hopper ------------------------------------------------------------

class ChannelHopper(threading.Thread):
    """Cycles through 2.4 GHz channels at a fixed dwell time."""

    def __init__(self, iface: str, channels: list, dwell: float):
        super().__init__(daemon=True)
        self.iface    = iface
        self.channels = channels
        self.dwell    = dwell
        self._stop    = threading.Event()

    def run(self):
        log.info(f"Channel hopper started: {self.channels} @ {self.dwell}s dwell")
        while not self._stop.is_set():
            for ch in self.channels:
                if self._stop.is_set():
                    break
                set_channel(self.iface, ch)
                time.sleep(self.dwell)

    def stop(self):
        self._stop.set()


# -- HTTP Forwarder ------------------------------------------------------------
# (identical contract to ble_feeder.Forwarder)

class Forwarder:
    def __init__(self, server_url: str, node_id: str,
                 batch_size: int = 10, flush_interval: float = 2.0,
                 token: str = ""):
        self.url            = server_url.rstrip("/") + "/ingest"
        self.node_id        = node_id
        self.batch_size     = batch_size
        self.flush_interval = flush_interval
        self.token          = token
        self.buffer         = []
        self.last_flush     = time.time()
        self.sent_total     = 0
        self.failed_total   = 0
        self._lock          = threading.Lock()

    def add(self, event: dict):
        with self._lock:
            self.buffer.append(event)
            if len(self.buffer) >= self.batch_size:
                self._flush_locked()

    def tick(self):
        with self._lock:
            if time.time() - self.last_flush >= self.flush_interval:
                self._flush_locked()
                self.last_flush = time.time()

    def _flush_locked(self):
        if not self.buffer:
            return
        payload      = {"node_id": self.node_id, "events": self.buffer.copy()}
        self.buffer.clear()
        try:
            headers = {"X-Node-Token": self.token} if self.token else {}
            r = requests.post(self.url, json=payload, headers=headers, timeout=5)
            r.raise_for_status()
            self.sent_total += len(payload["events"])
            log.debug(f"Forwarded {len(payload['events'])} events ({self.sent_total} total)")
        except requests.RequestException as e:
            self.failed_total += len(payload["events"])
            log.warning(f"Forward failed: {e} ({self.failed_total} events lost)")


# -- WiFi Feeder ---------------------------------------------------------------

class WiFiFeeder:
    def __init__(self, iface: str, node_id: str, server_url: str,
                 verbose: bool = False, batch_size: int = 10,
                 flush_interval: float = 2.0, channel_dwell: float = 0.2,
                 token: str = ""):
        self.iface       = iface
        self.node_id     = node_id
        self.verbose     = verbose
        self.token       = token
        self.start_time  = time.time()
        self.forwarder   = Forwarder(server_url, node_id, batch_size, flush_interval, token)
        self.hopper      = ChannelHopper(iface, CHANNELS_24, channel_dwell)
        self.count       = 0
        self.nan_count   = 0

    def _on_packet(self, pkt):
        # ---- Wi-Fi Beacon Remote ID ----
        rid_payload = extract_beacon_rid(pkt)
        if rid_payload is not None:
            self.count += 1
            decoded = decode_rid_message(rid_payload)
            mac     = pkt[Dot11].addr2 or ""
            rssi    = get_rssi(pkt)

            event = {
                "node_id":   self.node_id,
                "timestamp": time.time(),
                "radio":     "wifi_beacon",
                "mac":       mac,
                "rssi":      rssi,
                "payload":   rid_payload.hex().upper(),
                "decoded":   decoded,
            }

            if self.verbose or (decoded and decoded.get("message_type") == "Basic ID"):
                uas_id = decoded.get("uas_id", "") if decoded else ""
                log.info(
                    f"[WiFi-Beacon] MAC={mac}  RSSI={rssi}dBm  "
                    f"Type={decoded.get('message_type','?') if decoded else '?'}  "
                    f"UAS-ID={uas_id}"
                )

            self.forwarder.add(event)
            return

        # ---- Wi-Fi NAN Remote ID (detected, raw capture only) ----
        if is_nan_action(pkt):
            self.nan_count += 1
            mac  = pkt[Dot11].addr2 or ""
            rssi = get_rssi(pkt)
            raw  = bytes(pkt[Dot11].payload).hex().upper()

            if self.verbose:
                log.info(f"[WiFi-NAN] MAC={mac}  RSSI={rssi}dBm  raw={raw[:40]}...")

            event = {
                "node_id":   self.node_id,
                "timestamp": time.time(),
                "radio":     "wifi_nan",
                "mac":       mac,
                "rssi":      rssi,
                "payload":   raw,
                "decoded":   None,  # NAN full parsing is a future enhancement
            }
            self.forwarder.add(event)

    def run(self):
        log.info(f"DroneAware WiFi Feeder - Node: {self.node_id}")
        log.info(f"Interface: {self.iface}  |  Channels: {CHANNELS_24}")

        set_monitor_mode(self.iface)
        self.hopper.start()

        log.info("Scanning for Remote ID beacon frames (ASTM F3411)...")
        try:
            ticker = 0
            # sniff() blocks; we interleave tick() via a background flush thread
            flush_thread = threading.Thread(
                target=self._flush_loop, daemon=True
            )
            flush_thread.start()

            sniff(
                iface=self.iface,
                prn=self._on_packet,
                store=False,
                # No BPF filter — the rtl8188eu driver doesn't support "type mgt".
                # _on_packet() filters for Dot11Beacon and NAN action frames in Python.
            )
        except KeyboardInterrupt:
            log.info("Feeder stopped by user.")
        finally:
            self.hopper.stop()
            restore_managed_mode(self.iface)
            log.info(
                f"[Summary] Beacon RID={self.count}  NAN frames={self.nan_count}  "
                f"sent={self.forwarder.sent_total}  failed={self.forwarder.failed_total}"
            )

    def _flush_loop(self):
        """Periodically flush the forwarder buffer (runs in background thread)."""
        last_heartbeat = time.time()
        while True:
            time.sleep(1.0)
            self.forwarder.tick()
            if time.time() - last_heartbeat >= 60:
                last_heartbeat = time.time()
                log.info(
                    f"[Heartbeat] Beacon RID={self.count}  NAN={self.nan_count}  "
                    f"sent={self.forwarder.sent_total}  failed={self.forwarder.failed_total}"
                )
                if self.token:
                    try:
                        requests.post(
                            "https://api.droneaware.io/api/node/heartbeat",
                            json={
                                "node_id":    self.node_id,
                                "uptime_s":   int(time.time() - self.start_time),
                                "fw_version": "1.0.0",
                            },
                            headers={"X-Node-Token": self.token},
                            timeout=5,
                        )
                        log.debug("Heartbeat sent to droneaware.io")
                    except requests.RequestException as e:
                        log.warning(f"Heartbeat failed: {e}")


# -- Enrollment ----------------------------------------------------------------

TOKEN_FILE = "/etc/droneaware/token"


def resolve_token(node_id: str, enrollment_secret: str,
                  lat=None, lon=None, elevation_agl_m=None) -> str:
    """Return auth token, enrolling if necessary.

    Resolution order:
      1. Token file at TOKEN_FILE (written on first enrollment)
      2. POST /api/node/enroll with enrollment_secret (saves result to file)
      3. Empty string — unauthenticated (logs a warning)
    """
    if os.path.exists(TOKEN_FILE):
        token = open(TOKEN_FILE).read().strip()
        if token:
            log.info(f"Loaded token from {TOKEN_FILE}")
            return token

    if not enrollment_secret:
        log.warning("No token and no ENROLLMENT_SECRET — running unauthenticated")
        return ""

    log.info(f"Enrolling node {node_id} with droneaware.io ...")
    try:
        payload = {"node_id": node_id, "enrollment_secret": enrollment_secret}
        if lat is not None:
            payload["lat"] = lat
        if lon is not None:
            payload["lon"] = lon
        if elevation_agl_m is not None:
            payload["elevation_agl_m"] = elevation_agl_m

        r = requests.post(
            "https://api.droneaware.io/api/node/enroll",
            json=payload,
            timeout=10,
        )
        r.raise_for_status()
        data  = r.json()
        token = data["auth_token"]
        os.makedirs(os.path.dirname(TOKEN_FILE), exist_ok=True)
        with open(TOKEN_FILE, "w") as f:
            f.write(token)
        log.info(f"Enrolled successfully; token saved to {TOKEN_FILE}")

        claim_code = data.get("claim_code")
        claim_url  = data.get("claim_url")
        if claim_code and claim_url:
            msg = (
                "\n╔══════════════════════════════════════════════════════╗\n"
                f"║  Node {node_id} enrolled successfully.".ljust(55) + "║\n"
                "║  Claim this node to unlock enhanced features:        ║\n"
                f"║  {claim_url}".ljust(55) + "║\n"
                "║  Code expires in 48 hours.                           ║\n"
                "╚══════════════════════════════════════════════════════╝\n"
            )
            print(msg)
            try:
                os.makedirs("/etc/droneaware", exist_ok=True)
                with open("/etc/droneaware/claim.txt", "w") as f:
                    f.write(f"Node: {node_id}\n")
                    f.write(f"Claim URL: {claim_url}\n")
                    f.write(f"Claim code: {claim_code}\n")
            except Exception as e:
                print(f"Warning: could not save claim info: {e}")

        return token
    except Exception as e:
        log.error(f"Enrollment failed: {e} — running unauthenticated")
        return ""


# -- Entry Point ---------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="DroneAware WiFi Remote ID Feeder (Raspberry Pi + Alfa AWUS036N)"
    )
    parser.add_argument(
        "--iface", default="wlan1",
        help="Monitor-mode interface (default: wlan1)"
    )
    parser.add_argument(
        "--node-id", default=socket.gethostname(),
        help="Unique node ID (default: hostname)"
    )
    parser.add_argument(
        "--server", default="http://localhost:8000/api",
        help="DroneAware server base URL"
    )
    parser.add_argument(
        "--batch-size", type=int, default=10,
        help="Events per HTTP batch (default: 10)"
    )
    parser.add_argument(
        "--flush-interval", type=float, default=2.0,
        help="Max seconds between flushes (default: 2.0)"
    )
    parser.add_argument(
        "--channel-dwell", type=float, default=0.2,
        help="Seconds to dwell on each channel before hopping (default: 0.2)"
    )
    parser.add_argument(
        "--verbose", "-v", action="store_true",
        help="Log every decoded packet"
    )
    parser.add_argument(
        "--token", default=os.environ.get("NODE_TOKEN", ""),
        help="Node auth token (X-Node-Token header). Falls back to NODE_TOKEN env var."
    )
    parser.add_argument(
        "--enrollment-secret", default=os.environ.get("ENROLLMENT_SECRET", ""),
        help="Pre-shared secret for /api/node/enroll. Falls back to ENROLLMENT_SECRET env var."
    )
    args = parser.parse_args()

    lat           = float(os.environ.get("NODE_LAT", "0") or "0") or None
    lon           = float(os.environ.get("NODE_LON", "0") or "0") or None
    elevation_agl = float(os.environ.get("NODE_ELEVATION_AGL_M", "0") or "0") or None

    token = args.token or resolve_token(
        args.node_id,
        args.enrollment_secret,
        lat=lat,
        lon=lon,
        elevation_agl_m=elevation_agl,
    )

    feeder = WiFiFeeder(
        iface=args.iface,
        node_id=args.node_id,
        server_url=args.server,
        verbose=args.verbose,
        batch_size=args.batch_size,
        flush_interval=args.flush_interval,
        channel_dwell=args.channel_dwell,
        token=token,
    )
    feeder.run()


if __name__ == "__main__":
    main()
