#!/usr/bin/env python3
"""
DroneAware RTL-SDR Feeder - Remote ID Capture Script
Hardware: Dell Latitude 7389 + RTL-SDR Blog v3 (24-1766 MHz)
Captures RF Remote ID and drone telemetry signals and forwards to
the DroneAware server.

Supports:
  - ASTM F3411 Remote ID (when transmitted on supported frequencies)
  - LoRa drone telemetry (Semtech SX127x, 433/868/915 MHz)
  - ADS-B aircraft tracking (1090 MHz)
  - Proprietary drone control links (various sub-2.4 GHz bands)

Uses pyrtlsdr for SDR control (requires external dependency).

Usage:
    sudo python3 sdr_feeder.py --node-id NJ001 --server http://server/api

Requirements:
    pip3 install pyrtlsdr requests
    sudo apt install rtl-sdr librtlsdr-dev
"""

import threading
import subprocess
import time
import struct
import json
import logging
import argparse
import socket
import os
import sys
import requests
from typing import Optional, Dict, Any, List

try:
    from rtlsdr import RtlSdr
except ImportError:
    RtlSdr = None
    print("WARNING: pyrtlsdr not installed. Install with: pip3 install pyrtlsdr")

# -- Logging -------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler("/var/log/droneaware_sdr.log"),
    ],
)
log = logging.getLogger("droneaware.sdr")

# -- Constants -----------------------------------------------------------------

# Common drone telemetry frequencies (MHz)
FREQUENCIES = [
    433.92,   # LoRa ISM band (EU/US)
    868.0,    # LoRa ISM band (EU)
    915.0,    # LoRa ISM band (US)
    1090.0,   # ADS-B
    1575.42,  # GPS L1 (for interference detection)
]

# Sample rate for RTL-SDR (2.4 MSPS typical)
SAMPLE_RATE = 2400000

# Gain settings (auto or manual 0-49.6 dB)
GAIN = 'auto'

# Center frequency sweep dwell time (seconds)
DWELL_TIME = 0.5

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
# (mirrors ble_feeder.py and wifi_feeder.py — pure functions, no shared state)

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

    # Reject null/placeholder GPS values broadcast before GPS lock
    if abs(lat) > 90.0 or abs(lon) > 180.0:
        return {}

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


# -- Signal Detection ----------------------------------------------------------

def detect_signal_peaks(samples: List[float], threshold_db: float = -40.0) -> List[int]:
    """
    Detect signal peaks in IQ samples above threshold.
    Returns list of peak indices.
    """
    peaks = []
    power = [abs(s)**2 for s in samples]
    avg_power = sum(power) / len(power) if power else 0
    threshold_linear = 10 ** (threshold_db / 10) * avg_power
    
    window = 10
    for i in range(window, len(power) - window):
        if power[i] > threshold_linear:
            is_peak = True
            for j in range(i - window, i + window + 1):
                if j != i and power[j] >= power[i]:
                    is_peak = False
                    break
            if is_peak:
                peaks.append(i)
    
    return peaks


def extract_payload_from_samples(samples: List[float], sample_rate: int, freq_mhz: float) -> Optional[bytes]:
    """
    Attempt to extract potential Remote ID or telemetry payload from IQ samples.
    This is a simplified implementation - production would use proper demodulation.
    
    Returns decoded bytes or None if no valid payload found.
    """
    if len(samples) < 100:
        return None
    
    # Simple energy detection and bit extraction
    # In production, this would use proper ASK/FSK/OOK demodulation
    peaks = detect_signal_peaks(samples)
    
    if len(peaks) < 10:
        return None
    
    # Convert peak positions to bits (simplified)
    bits = []
    for i in range(len(peaks) - 1):
        gap = peaks[i+1] - peaks[i]
        bits.append(1 if gap < 50 else 0)
    
    # Convert bits to bytes
    if len(bits) < 8:
        return None
    
    payload_bytes = bytearray()
    for i in range(0, len(bits) - 7, 8):
        byte_val = 0
        for j in range(8):
            byte_val = (byte_val << 1) | bits[i + j]
        payload_bytes.append(byte_val)
    
    # Validate if it looks like a Remote ID message
    if len(payload_bytes) >= 25:
        # Check for Basic ID message pattern
        msg_type = (payload_bytes[0] >> 4) & 0x0F
        if msg_type in MSG_TYPE:
            return bytes(payload_bytes[:25])
    
    return bytes(payload_bytes) if payload_bytes else None


# -- Frequency Sweeper ---------------------------------------------------------

class FrequencySweeper(threading.Thread):
    """Cycles through configured frequencies at a fixed dwell time."""

    def __init__(self, sdr: RtlSdr, frequencies: List[float], dwell: float):
        super().__init__(daemon=True)
        self.sdr = sdr
        self.frequencies = frequencies
        self.dwell = dwell
        self._stop = threading.Event()
        self.current_freq = frequencies[0] if frequencies else 433.92

    def run(self):
        log.info(f"Frequency sweeper started: {self.frequencies} @ {self.dwell}s dwell")
        while not self._stop.is_set():
            for freq in self.frequencies:
                if self._stop.is_set():
                    break
                try:
                    self.sdr.set_center_freq(freq * 1e6)
                    self.current_freq = freq
                    log.debug(f"Tuned to {freq} MHz")
                except Exception as e:
                    log.warning(f"Failed to tune to {freq} MHz: {e}")
                time.sleep(self.dwell)

    def stop(self):
        self._stop.set()


# -- HTTP Forwarder ------------------------------------------------------------
# (identical contract to ble_feeder.Forwarder and wifi_feeder.Forwarder)

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


# -- Local Publisher -----------------------------------------------------------

class LocalPublisher:
    """
    Writes decoded detections to a tmpfs ring buffer and UDP LAN broadcast.

    Buffer: /run/droneaware/detections.jsonl  (RAM only — gone on reboot,
            zero SD card wear). Bounded to MAX_LINES entries.
    UDP:    255.255.255.255:9999 — any device on the LAN can listen.
    """
    BUFFER_PATH = "/run/droneaware/detections.jsonl"
    UDP_PORT    = 9999
    MAX_LINES   = 3600  # ~60 min at 1 event/sec

    def __init__(self):
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        os.makedirs(os.path.dirname(self.BUFFER_PATH), exist_ok=True)
        self._line_count = 0

    def publish(self, event: dict):
        decoded = event.get("decoded") or {}
        if not decoded:
            return

        record = {
            "t":     event.get("timestamp") or event.get("observed_at"),
            "mac":   event.get("source_mac") or event.get("mac"),
            "radio": event.get("radio"),
            "rssi":  event.get("rssi"),
            "type":  decoded.get("message_type"),
            "lat":   decoded.get("latitude"),
            "lon":   decoded.get("longitude"),
            "alt":   decoded.get("altitude_geo"),
            "speed": decoded.get("ground_speed"),
            "hdg":   decoded.get("heading"),
            "id":    decoded.get("uas_id"),
        }
        line = json.dumps(record, separators=(',', ':'))

        try:
            self._sock.sendto((line + '\n').encode(), ('255.255.255.255', self.UDP_PORT))
        except Exception:
            pass

        try:
            with open(self.BUFFER_PATH, 'a') as f:
                f.write(line + '\n')
            self._line_count += 1
            if self._line_count > self.MAX_LINES:
                self._trim()
        except Exception:
            pass

    def _trim(self):
        try:
            with open(self.BUFFER_PATH, 'r') as f:
                lines = f.readlines()
            if len(lines) > self.MAX_LINES:
                with open(self.BUFFER_PATH, 'w') as f:
                    f.writelines(lines[-self.MAX_LINES:])
            self._line_count = min(len(lines), self.MAX_LINES)
        except Exception:
            pass


# -- SDR Feeder ----------------------------------------------------------------

class SDRFeeder:
    def __init__(self, node_id: str, server_url: str,
                 verbose: bool = False, batch_size: int = 10,
                 flush_interval: float = 2.0, freq_dwell: float = 0.5,
                 gain: Any = 'auto', frequencies: List[float] = None,
                 token: str = ""):
        self.iface       = "rtl_sdr"
        self.node_id     = node_id
        self.verbose     = verbose
        self.token       = token
        self.start_time  = time.time()
        self.forwarder   = Forwarder(server_url, node_id, batch_size, flush_interval, token)
        self.publisher   = LocalPublisher()
        self.frequencies = frequencies or FREQUENCIES
        self.gain        = gain
        self.freq_dwell  = freq_dwell
        self.count       = 0
        self.sdr         = None
        self.sweeper     = None

    def _on_samples(self, samples: List[float], freq_mhz: float):
        """Process IQ samples and extract potential Remote ID messages."""
        
        # Calculate signal strength (RSSI estimate)
        power = sum(abs(s)**2 for s in samples) / len(samples) if samples else 0
        rssi = 10 * (power ** 0.5) - 100  # Rough RSSI estimate in dBm
        
        # Skip if signal too weak
        if rssi < -80:
            return
        
        # Try to extract payload
        payload = extract_payload_from_samples(samples, SAMPLE_RATE, freq_mhz)
        
        if payload is None:
            return
        
        # Try to decode as Remote ID
        decoded = decode_rid_message(payload)
        if decoded is None:
            return
        
        # Unpack Message Pack into individual sub-messages
        if decoded.get("message_type") == "Message Pack":
            sub_messages = decoded.get("messages", [])
        else:
            sub_messages = [decoded]

        ts = time.time()
        for msg in sub_messages:
            # Drop Location/Vector messages with no valid GPS fix
            if msg.get("message_type") == "Location/Vector" and "latitude" not in msg:
                continue
            
            self.count += 1
            raw_hex = msg.get("raw_hex", payload.hex().upper())
            event = {
                "node_id":   self.node_id,
                "timestamp": ts,
                "radio":     f"sdr_{freq_mhz}mhz",
                "mac":       f"SDR:{freq_mhz:.2f}",
                "rssi":      round(rssi, 1),
                "payload":   raw_hex,
                "decoded":   msg,
                "frequency": freq_mhz,
            }
            
            if self.verbose or msg.get("message_type") in ("Basic ID", "Location/Vector"):
                mtype  = msg.get("message_type", "?")
                uas_id = msg.get("uas_id", "")
                lat    = msg.get("latitude", "")
                lon    = msg.get("longitude", "")
                detail = f"UAS-ID={uas_id}" if uas_id else f"lat={lat} lon={lon}" if lat else ""
                log.info(
                    f"[SDR-{freq_mhz:.2f}MHz] RSSI={rssi:.1f}dBm  "
                    f"Type={mtype}  {detail}"
                )
            
            self.forwarder.add(event)
            self.publisher.publish(event)

    def run(self):
        if RtlSdr is None:
            log.error("pyrtlsdr library not available. Install with: pip3 install pyrtlsdr")
            log.error("Also ensure rtl-sdr drivers are installed: sudo apt install rtl-sdr librtlsdr-dev")
            sys.exit(1)
        
        log.info(f"DroneAware RTL-SDR Feeder - Node: {self.node_id}")
        log.info(f"Device: RTL-SDR Blog v3  |  Frequencies: {self.frequencies}")
        log.info(f"Sample Rate: {SAMPLE_RATE} sps  |  Gain: {self.gain}")

        # Initialize RTL-SDR
        try:
            self.sdr = RtlSdr()
            log.info(f"Found RTL-SDR device: {self.sdr.get_device_names()[0]}")
        except Exception as e:
            log.error(f"Failed to initialize RTL-SDR: {e}")
            log.error("Ensure the device is connected and rtl-sdr drivers are installed.")
            sys.exit(1)

        # Configure SDR
        self.sdr.set_sample_rate(SAMPLE_RATE)
        if self.gain != 'auto':
            self.sdr.set_gain(float(self.gain))
        else:
            self.sdr.set_gain('auto')
        
        # Start frequency sweeper
        self.sweeper = FrequencySweeper(self.sdr, self.frequencies, self.freq_dwell)
        self.sweeper.start()

        log.info(f"Scanning for Remote ID and telemetry signals on {self.frequencies}...")

        flush_thread = threading.Thread(target=self._flush_loop, daemon=True)
        flush_thread.start()

        try:
            while True:
                try:
                    # Read samples from SDR
                    samples = self.sdr.read_samples(512)
                    
                    # Process samples
                    if samples is not None and len(samples) > 0:
                        self._on_samples(samples, self.sweeper.current_freq)
                        
                except KeyboardInterrupt:
                    raise
                except Exception as e:
                    log.warning(f"Error reading samples: {e}")
                    time.sleep(0.1)
                    
        except KeyboardInterrupt:
            log.info("Feeder stopped by user.")
        finally:
            if self.sweeper:
                self.sweeper.stop()
            if self.sdr:
                self.sdr.close()
            log.info(
                f"[Summary] RID messages={self.count}  "
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
                    f"[Heartbeat] RID={self.count}  "
                    f"sent={self.forwarder.sent_total}  failed={self.forwarder.failed_total}"
                )
                if self.token:
                    try:
                        requests.post(
                            "https://api.droneaware.io/api/node/heartbeat",
                            json={
                                "node_id":    self.node_id,
                                "uptime_s":   int(time.time() - self.start_time),
                                "fw_version": "1.0.14",
                            },
                            headers={"X-Node-Token": self.token},
                            timeout=5,
                        )
                        log.debug("Heartbeat sent to droneaware.io")
                    except requests.RequestException as e:
                        log.warning(f"Heartbeat failed: {e}")


# -- Enrollment ----------------------------------------------------------------

TOKEN_FILE = "/etc/droneaware/token"


def resolve_token() -> str:
    """Load the node credential written by the installer.

    Exits with a clear error if the credential is missing — enrollment
    is handled entirely by the installer, not the feeder.
    """
    if os.path.exists(TOKEN_FILE):
        token = open(TOKEN_FILE).read().strip()
        if token:
            log.info(f"Loaded node credential from {TOKEN_FILE}")
            return token

    log.error("No node credential found at %s.", TOKEN_FILE)
    log.error("This node has not been enrolled. Run the DroneAware installer:")
    log.error("  curl -fsSL https://droneaware.io/install | sudo bash")
    sys.exit(1)


# -- Entry Point ---------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="DroneAware RTL-SDR Remote ID Feeder (Dell Latitude 7389 + RTL-SDR Blog v3)"
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
        "--freq-dwell", type=float, default=0.5,
        help="Seconds to dwell on each frequency before sweeping (default: 0.5)"
    )
    parser.add_argument(
        "--gain", default='auto',
        help="LNA gain in dB (0-49.6) or 'auto' (default: auto)"
    )
    parser.add_argument(
        "--frequencies", type=float, nargs='+', default=None,
        help=f"Frequencies to scan in MHz (default: {FREQUENCIES})"
    )
    parser.add_argument(
        "--verbose", "-v", action="store_true",
        help="Log every decoded packet"
    )
    args = parser.parse_args()

    token = resolve_token()

    feeder = SDRFeeder(
        node_id=args.node_id,
        server_url=args.server,
        verbose=args.verbose,
        batch_size=args.batch_size,
        flush_interval=args.flush_interval,
        freq_dwell=args.freq_dwell,
        gain=args.gain,
        frequencies=args.frequencies,
        token=token,
    )
    feeder.run()


if __name__ == "__main__":
    main()
