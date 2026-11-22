#!/usr/bin/env bash
# Build the Raspberry Pi 4 firmware.
#   NERVES_WIFI_SSID="hotspot" NERVES_WIFI_PASSPHRASE="clave" OPDOC_NODES="172.20.10.4,172.20.10.5" ./fw.sh
#   ./fw.sh burn            # build + write to the microSD (asks for confirmation)
#   ./fw.sh upload <ip>     # build + update a running Pi over SSH (keeps /root)
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh
export MIX_TARGET=rpi4
[ -d "$MIX_DEPS_PATH/nerves_system_rpi4" ] || mix deps.get
[ -z "${NERVES_WIFI_SSID:-}" ] && echo "WARNING: NERVES_WIFI_SSID not set: wlan0 will not be configured (use usb0/eth0 or VintageNetWiFi.quick_configure/2)"
mix firmware
case "${1:-}" in
  burn) mix burn ;;
  upload) mix upload "${2:?ip}" ;;
esac
echo "Firmware: $MIX_BUILD_ROOT/rpi4_dev/nerves/images/opdoc.fw"
