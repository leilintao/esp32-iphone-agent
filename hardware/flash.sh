#!/usr/bin/env bash
# Build and flash the board (needs arduino-cli and the esp32 core 3.3.x).
# Usage: hardware/flash.sh [port] [--debug] [--sta] [--build-only]
#   --debug       log commands and the AirPlay handshake on USB serial
#   --sta         test build: join the Wi-Fi in hid_bridge/secrets.h instead of opening a hotspot
#   --build-only  compile only (prints flash/RAM usage)
#   --ap-tune     A/B build: hotspot on a 20 MHz channel with 300 TU beacons (more airtime for BLE)
#   --display-es3c28p  enable LCDWIKI ES3C28P/ES3N28P ILI9341 status screen
#   --minimal-es3c28p A/B diagnostic: force backlight/amp off, no display/audio
# BLE host: h2zero NimBLE-Arduino (arduino-cli lib install "NimBLE-Arduino"); its buffer sizes live in
# hid_bridge/nimble_cfg.h, force-included into every C/C++ file below.
# A running bridge is a TinyUSB device, so it is first kicked into the ROM
# bootloader with a 1200-baud touch; a blank board is flashed directly.
set -euo pipefail
cd "$(dirname "$0")"
FQBN="esp32:esp32:esp32s3:USBMode=default,CDCOnBoot=cdc,FlashSize=8M,PSRAM=opi,PartitionScheme=default_8MB"
ports() { for p in /dev/cu.usbmodem* /dev/ttyACM*; do [[ -e $p ]] && echo "$p"; done; return 0; }
port() { ports | head -n 1; }
PORT="" DEFS="" BUILD_ONLY=0 UPLOAD_ONLY=0
for a in "$@"; do
  case $a in
    --debug) DEFS+=" -DAGENT_DEBUG_SERIAL=1" ;;
    --sta) [[ -f hid_bridge/secrets.h ]] || { echo "--sta needs hid_bridge/secrets.h (see secrets.example.h)"; exit 1; }
           DEFS+=" -DSTA_FROM_SECRETS=1" ;;
    --build-only) BUILD_ONLY=1 ;;
    --upload-only) UPLOAD_ONLY=1 ;;
    --ap-tune) DEFS+=" -DAP_TUNE=1" ;;
    --display-es3c28p) DEFS+=" -DSTATUS_DISPLAY_ES3C28P=1" ;;
    --minimal-es3c28p) DEFS+=" -DDIAGNOSTIC_MINIMAL_ES3C28P=1" ;;
    *) PORT=$a ;;
  esac
done
if [[ "$DEFS" == *STATUS_DISPLAY_ES3C28P* && "$DEFS" == *DIAGNOSTIC_MINIMAL_ES3C28P* ]]; then
  echo "choose either --display-es3c28p or --minimal-es3c28p, not both"
  exit 1
fi
[[ $PWD != *" "* ]] || { echo "the -include path below cannot contain spaces: $PWD"; exit 1; }
DEFS+=" -include $PWD/hid_bridge/nimble_cfg.h"
FLAGS=(--build-property "compiler.cpp.extra_flags=$DEFS" --build-property "compiler.c.extra_flags=$DEFS")

(( UPLOAD_ONLY )) || arduino-cli compile -b "$FQBN" "${FLAGS[@]}" --output-dir build hid_bridge
(( BUILD_ONLY )) && exit 0
PORT=${PORT:-$(port)}
[[ -n "$PORT" ]] || { echo "no USB serial port found"; exit 1; }
BEFORE=$(ports)
stty -f "$PORT" 1200 2>/dev/null || stty -F "$PORT" 1200 2>/dev/null || true
NEW=""
for _ in $(seq 20); do
  sleep 0.5
  for p in $(ports); do
    if ! grep -qxF "$p" <<<"$BEFORE"; then NEW=$p; break 2; fi
  done
done
sleep 1  # let the ROM bootloader's serial come up
if [[ -n "$NEW" ]]; then PORT=$NEW; elif [[ ! -e "$PORT" ]]; then PORT=$(port || true); fi
[[ -n "$PORT" && -e "$PORT" ]] || { echo "USB bootloader port did not appear after the 1200-baud reset"; exit 1; }
arduino-cli upload -b "$FQBN" -p "$PORT" --input-dir build hid_bridge
