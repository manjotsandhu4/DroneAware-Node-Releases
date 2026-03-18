#!/usr/bin/env python3
"""
DroneAware BLE Feeder - Remote ID Capture Script
Hardware: Raspberry Pi 4 + USB Bluetooth Adapter (Sena UD100 / CSR)

Captures BLE Remote ID advertisements (ASTM F3411 / UUID 0xFFFA) and forwards
raw payloads to the DroneAware server in 5-second batches.

The node does NO ODID decoding — all interpretation is done server-side.

Usage:
    sudo python3 ble_feeder.py --node-id NJ001 --server https://your-server/api

Requirements:
    pip3 install bleak requests
    sudo apt install bluetooth bluez
"""

import asyncio
import logging
import argparse
import time
import socket
import collections
import os
import subprocess
import sys
import requests
from datetime import datetime, timezone
from bleak import BleakScanner
from bleak.backends.device import BLEDevice
from bleak.backends.scanner import AdvertisementData

# -- Logging -------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler("/var/log/droneaware_ble.log"),
    ],
)
log = logging.getLogger("droneaware.ble")

# -- Constants -----------------------------------------------------------------
REMOTE_ID_SERVICE_UUID = "0000fffa-0000-1000-8000-00805f9b34fb"
MAX_BUFFER = 1000  # ring buffer capacity (events); oldest dropped when full


# -- Adapter Resolution --------------------------------------------------------

def find_adapter_by_mac(target_mac: str) -> str | None:
    """
    Resolve a Bluetooth adapter MAC address to its HCI device name (e.g. 'hci0').
    Parses hciconfig output — immune to index changes across reboots.
    """
    import re
    target = target_mac.lower().strip()
    try:
        out = subprocess.check_output(["hciconfig", "-a"], text=True, stderr=subprocess.DEVNULL)
    except Exception:
        return None
    # Each block starts with "hciN:" followed by "BD Address: XX:XX:XX:XX:XX:XX"
    current = None
    for line in out.splitlines():
        m = re.match(r'^(hci\d+):', line)
        if m:
            current = m.group(1)
        if current and "BD Address:" in line:
            addr = re.search(r'BD Address:\s+([0-9A-Fa-f:]{17})', line)
            if addr and addr.group(1).lower() == target:
                return current
    return None


# -- Health Checks -------------------------------------------------------------

def get_cpu_temp() -> float | None:
    try:
        with open("/sys/class/thermal/thermal_zone0/temp") as f:
            return round(int(f.read().strip()) / 1000.0, 1)
    except Exception:
        return None


def get_ble_health(adapter: str = "hci0") -> tuple[bool, str]:
    try:
        result = subprocess.run(
            ["hciconfig", adapter],
            capture_output=True, text=True, timeout=5,
        )
        return "UP RUNNING" in result.stdout, adapter
    except Exception:
        return False, adapter


def get_wifi_health(adapter: str | None) -> tuple[bool | None, str | None]:
    if not adapter:
        return None, None
    try:
        path = f"/sys/class/net/{adapter}/operstate"
        if not os.path.exists(path):
            return False, adapter
        with open(path) as f:
            state = f.read().strip()
        return state in ("up", "unknown"), adapter
    except Exception:
        return False, adapter


# -- Payload Extraction --------------------------------------------------------

def extract_rid_payload(service_data: bytes) -> tuple[str, str] | tuple[None, None]:
    """
    Strip the 2-byte ASTM header (App Code 0x0D + counter) from BLE service
    data and return (rid_payload_hex, strategy).

    ASTM F3411-22a BLE service data layout:
      Byte 0:    App Code (0x0D)
      Byte 1:    Rotation counter
      Bytes 2-26: 25-byte ODID message

    Returns (None, None) if the data doesn't match any known format.
    """
    if len(service_data) == 27 and service_data[0] == 0x0D:
        return service_data[2:].hex(), "tail25_of_27"
    if len(service_data) == 26 and service_data[0] == 0x0D:
        return service_data[1:].hex(), "tail25_of_26"
    if len(service_data) == 25:
        return service_data.hex(), "raw25"
    return None, None


# -- HTTP Forwarder ------------------------------------------------------------

class Forwarder:
    """
    Buffers raw BLE events and POSTs 5-second batches to the DroneAware server.

    Uses a ring buffer (deque with maxlen) so that if the uplink is down for an
    extended period, oldest events are dropped rather than consuming unbounded
    memory. Failed batches are re-queued at the front of the buffer.
    """

    def __init__(self, server_url: str, node_id: str,
                 batch_size: int = 200, flush_interval: float = 5.0,
                 token: str = ""):
        self.url            = server_url.rstrip("/") + "/ingest"
        self.node_id        = node_id
        self.batch_size     = batch_size
        self.flush_interval = flush_interval
        self.token          = token
        self.buffer         = collections.deque(maxlen=MAX_BUFFER)
        self.last_flush     = time.monotonic()
        self.sent_total     = 0
        self.dropped_total  = 0

    def add(self, event: dict):
        self.buffer.append(event)
        if len(self.buffer) >= self.batch_size:
            self._flush()

    def tick(self):
        """Time-based flush — call once per second from the main loop."""
        if time.monotonic() - self.last_flush >= self.flush_interval:
            self._flush()
            self.last_flush = time.monotonic()

    def _flush(self):
        if not self.buffer:
            return

        batch = list(self.buffer)
        self.buffer.clear()

        payload = {
            "node_id":     self.node_id,
            "received_at": datetime.now(timezone.utc).isoformat(),
            "count":       len(batch),
            "events":      batch,
        }

        try:
            headers = {"X-Node-Token": self.token} if self.token else {}
            r = requests.post(self.url, json=payload, headers=headers, timeout=5)
            r.raise_for_status()
            self.sent_total += len(batch)
            log.debug(f"Sent {len(batch)} events ({self.sent_total} total)")
        except requests.RequestException as e:
            # Re-queue failed events at the front of the ring buffer.
            # deque(maxlen) auto-drops the oldest if we exceed capacity.
            space_before = MAX_BUFFER - len(self.buffer)
            for event in reversed(batch):
                self.buffer.appendleft(event)
            newly_dropped = max(0, len(batch) - space_before)
            self.dropped_total += newly_dropped
            log.warning(
                f"Flush failed: {e}  "
                f"(buffered={len(self.buffer)}, dropped_total={self.dropped_total})"
            )


# -- BLE Feeder ----------------------------------------------------------------

class BLEFeeder:
    def __init__(self, node_id: str, server_url: str, adapter: str = "hci0",
                 verbose: bool = False, batch_size: int = 200,
                 flush_interval: float = 5.0, token: str = "",
                 wifi_adapter: str | None = None):
        self.node_id      = node_id
        self.adapter      = adapter
        self.wifi_adapter = wifi_adapter
        self.verbose      = verbose
        self.token        = token
        self.start_time   = time.monotonic()
        self.forwarder    = Forwarder(server_url, node_id, batch_size, flush_interval, token)
        self.count        = 0

    def on_advertisement(self, device: BLEDevice, adv: AdvertisementData):
        """Callback for every BLE advertisement containing UUID 0xFFFA service data."""
        # Locate the FFFA service data entry
        svc_data  = None
        svc_uuid  = None
        for uuid, data in adv.service_data.items():
            if "fffa" in uuid.lower():
                svc_data = data
                svc_uuid = uuid
                break

        if svc_data is None:
            return

        rid_payload_hex, strategy = extract_rid_payload(svc_data)
        if rid_payload_hex is None:
            log.warning(
                f"Unrecognised service data from {device.address} "
                f"({len(svc_data)} bytes: {svc_data.hex()}) — skipped"
            )
            return

        self.count += 1

        event = {
            "node_id":              self.node_id,
            "observed_at":          datetime.now(timezone.utc).isoformat(),
            "observed_monotonic":   time.monotonic(),
            "radio":                "ble",
            "source_mac":           device.address,
            "source_name":          device.name or None,
            "rssi":                 adv.rssi,
            "tx_power":             getattr(adv, "tx_power", None),
            "service_uuid":         svc_uuid,
            "service_data_hex":     svc_data.hex(),
            "service_data_len":     len(svc_data),
            "rid_payload_hex":      rid_payload_hex,
            "rid_payload_strategy": strategy,
            "adapter":              self.adapter,
        }

        if self.verbose:
            log.info(
                f"[BLE] MAC={device.address}  RSSI={adv.rssi}dBm  "
                f"payload={rid_payload_hex[:16]}...  strategy={strategy}"
            )

        self.forwarder.add(event)

    async def run(self):
        log.info(f"DroneAware BLE Feeder - Node: {self.node_id}  Adapter: {self.adapter}")
        log.info(f"Scanning for Remote ID broadcasts (UUID 0xFFFA)...")

        # No service_uuids filter here — the CSR adapter doesn't reliably
        # support BlueZ's UUID pre-filter. We filter for 0xFFFA in the callback.
        scanner = BleakScanner(
            detection_callback=self.on_advertisement,
            adapter=self.adapter,
        )

        async with scanner:
            ticker = 0
            while True:
                await asyncio.sleep(1.0)
                self.forwarder.tick()
                ticker += 1

                if ticker % 60 == 0:
                    cpu_temp          = get_cpu_temp()
                    ble_ok, ble_adp   = get_ble_health(self.adapter)
                    wifi_ok, wifi_adp = get_wifi_health(self.wifi_adapter)

                    log.info(
                        f"[Heartbeat] seen={self.count}  "
                        f"sent={self.forwarder.sent_total}  "
                        f"dropped={self.forwarder.dropped_total}  "
                        f"buffered={len(self.forwarder.buffer)}  "
                        f"temp={cpu_temp}°C  ble={ble_ok}  wifi={wifi_ok}"
                    )
                    if self.token:
                        try:
                            requests.post(
                                "https://api.droneaware.io/api/node/heartbeat",
                                json={
                                    "node_id":      self.node_id,
                                    "uptime_s":     int(time.monotonic() - self.start_time),
                                    "fw_version":   "1.0.0",
                                    "cpu_temp_c":   cpu_temp,
                                    "ble_ok":       ble_ok,
                                    "wifi_ok":      wifi_ok,
                                    "ble_adapter":  ble_adp,
                                    "wifi_adapter": wifi_adp,
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
        description="DroneAware BLE Remote ID Feeder"
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
        "--adapter", default="hci0",
        help="HCI adapter to use for scanning (default: hci0)"
    )
    parser.add_argument(
        "--adapter-mac", default=None,
        help="Resolve adapter by BD address instead of HCI index (recommended — immune to reboot index swaps)"
    )
    parser.add_argument(
        "--batch-size", type=int, default=200,
        help="Max events per batch before forcing a flush (default: 200)"
    )
    parser.add_argument(
        "--flush-interval", type=float, default=5.0,
        help="Seconds between time-based flushes (default: 5.0)"
    )
    parser.add_argument(
        "--verbose", "-v", action="store_true",
        help="Log every received packet"
    )
    args = parser.parse_args()

    wifi_adapter = os.environ.get("WIFI_ADAPTER") or None
    token        = resolve_token()

    adapter = args.adapter
    if args.adapter_mac:
        resolved = find_adapter_by_mac(args.adapter_mac)
        if resolved:
            log.info(f"Resolved adapter MAC {args.adapter_mac} -> {resolved}")
            adapter = resolved
        else:
            log.error(f"No adapter found with MAC {args.adapter_mac} — falling back to {adapter}")

    feeder = BLEFeeder(
        node_id=args.node_id,
        server_url=args.server,
        adapter=adapter,
        verbose=args.verbose,
        batch_size=args.batch_size,
        flush_interval=args.flush_interval,
        token=token,
        wifi_adapter=wifi_adapter,
    )

    try:
        asyncio.run(feeder.run())
    except KeyboardInterrupt:
        log.info("Feeder stopped by user.")


if __name__ == "__main__":
    main()
