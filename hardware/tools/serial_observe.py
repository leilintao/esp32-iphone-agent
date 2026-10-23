# /// script
# dependencies = ["pyserial>=3.5"]
# ///
"""Record a board's USB diagnostics. The ONLY command sent is `status`, never HID.

Use 115200 baud with an explicit port. Does not reset the board, change Wi-Fi,
subscribe to video or follow another serial device if this one disappears.
"""
import argparse
import json
import os
from pathlib import Path
import time
import serial


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True)
    parser.add_argument("--seconds", type=float, default=90)
    parser.add_argument("--log", type=Path, required=True)
    args = parser.parse_args()
    if args.seconds <= 0:
        parser.error("--seconds must be positive")
    # Exclusive creation prevents accidentally overwriting previous evidence.
    fd = os.open(args.log, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    previous_up = None
    statuses = 0
    resets = 0
    started = time.monotonic()
    link = serial.Serial(port=None, baudrate=115200, timeout=0.2)
    link.rts = False
    link.dtr = True  # native USB CDC needs an open host; never use 1200 baud
    link.port = args.port
    with os.fdopen(fd, "w", buffering=1) as log:
        log.write(f"observer start {time.strftime('%Y-%m-%dT%H:%M:%S%z')} port={args.port}\n")
        try:
            link.open()
            deadline = started + args.seconds
            next_status = 0
            while time.monotonic() < deadline:
                if time.monotonic() >= next_status:
                    link.write(b"990900 status\n")
                    next_status = time.monotonic() + 3
                line = link.readline().decode(errors="replace").strip()
                if not line:
                    continue
                log.write(f"{time.monotonic() - started:.3f} {line}\n")
                if line.startswith("990900 ok "):
                    status = json.loads(line.removeprefix("990900 ok "))
                    up = status.get("up")
                    if previous_up is not None and up is not None and up < previous_up:
                        resets += 1
                    if up is not None:
                        previous_up = up
                    statuses += 1
                    print("STATUS", json.dumps({key: status.get(key) for key in
                        ("up", "rst", "variant", "heap", "psram", "usb", "ap", "sta", "vwait", "vpending")}), flush=True)
                elif any(word in line.lower() for word in
                         ("boot ", "panic", "brownout", "watchdog", "backtrace", "assert", "abort")):
                    print("BOOT/ERROR", line[:500], flush=True)
            summary = {"seconds": round(time.monotonic() - started, 1), "statuses": statuses,
                       "uptime_rollbacks": resets, "last_up": previous_up}
            log.write("SUMMARY " + json.dumps(summary) + "\n")
            print("SUMMARY", json.dumps(summary), flush=True)
        except serial.SerialException as error:
            log.write("USB_DISCONNECTED " + str(error) + "\n")
            print("USB_DISCONNECTED", str(error), flush=True)
            raise SystemExit(2)
        finally:
            link.close()


if __name__ == "__main__":
    main()
