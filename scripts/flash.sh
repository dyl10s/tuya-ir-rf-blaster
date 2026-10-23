#!/usr/bin/env bash
#
# flash.sh - flash a Tuya IR+RF blaster (BK7231N) with ESPHome Kickstart
#            using tuya-cloudcutter, then point you at the OTA step.
#
# This automates the manual cloudcutter flow:
#   1. pre-flight checks (iw, adapter, AP mode, profile, firmware, docker)
#   2. put the device into AP mode
#   3. run cloudcutter to install ESPHome Kickstart
#   4. print the captive-portal + OTA instructions
#
# WARNING: cloudcutter hands the Wi-Fi adapter to its container, so the
# machine running this WILL lose network access during the flash (unless it
# has a wired connection). Run it from a local console, not over SSH.
#
# Usage:
#   ./scripts/flash.sh                 # auto-detect adapter, use defaults
#   ADAPTER=wlan0 ./scripts/flash.sh   # force an adapter
#   PROFILE=... FWFILE=... ./scripts/flash.sh
#
# Environment:
#   ADAPTER         wireless interface (default: first one found)
#   CLOUDCUTTER_DIR tuya-cloudcutter checkout (default: ~/tuya-cloudcutter)
#   PROFILE         device profile name
#   FWFILE          kickstart firmware filename inside custom-firmware/
#   ALLOW_SSH=1     skip the SSH safety stop (only if you have ethernet)
#
set -u

CLOUDCUTTER_DIR="${CLOUDCUTTER_DIR:-$HOME/tuya-cloudcutter}"
PROFILE="${PROFILE:-tuya-generic-ir-rf-universal-remote-controller-v2.0.8}"
FWFILE="${FWFILE:-kickstart-bk7231n-tuya-2026-10-06.ota.ug.bin}"
ADAPTER="${ADAPTER:-}"

c_ok()   { printf '  \033[32m[ OK ]\033[0m %s\n' "$1"; }
c_bad()  { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; }
c_warn() { printf '  \033[33m[WARN]\033[0m %s\n' "$1"; }
c_note() { printf '         %s\n' "$1"; }
c_hdr()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

clear 2>/dev/null || true
echo "=============================================================="
echo " TUYA IR/RF BLASTER -> ESPHOME KICKSTART"
echo " Firmware: $FWFILE"
echo " Profile : $PROFILE"
echo "=============================================================="

# ---------------------------------------------------------------------------
c_hdr "STEP 1 of 4 - Pre-flight checks"
# ---------------------------------------------------------------------------
if command -v iw >/dev/null 2>&1; then
    c_ok "iw installed"
else
    c_bad "iw is not installed. Cloudcutter requires it on the host."
    c_note "Fix with:  sudo apt install -y iw    then re-run."
    exit 1
fi

if [ -n "${SSH_CONNECTION:-}" ] || [ -n "${SSH_TTY:-}" ]; then
    if ip -br link 2>/dev/null | awk '$1 ~ /^(eth|enp|eno|ens|enx)/ {found=1} END {exit !found}'; then
        c_warn "SSH session detected, but wired ethernet is present."
        c_note "The flash should not kill your SSH connection. Continuing."
    elif [ "${ALLOW_SSH:-0}" = "1" ]; then
        c_warn "SSH session with no ethernet, ALLOW_SSH=1 set. You will be disconnected."
    else
        c_bad "You are in an SSH session with no wired ethernet."
        c_note "The flash cuts Wi-Fi and kills SSH mid-write."
        c_note "Run this from the laptop's own screen and keyboard,"
        c_note "or set ALLOW_SSH=1 if you know what you are doing."
        exit 1
    fi
else
    c_ok "Local console detected (not SSH)"
fi

if [ -z "$ADAPTER" ]; then
    ADAPTER="$(ip -br link 2>/dev/null | awk '$1 ~ /^(wl|wlan|wifi)/ {print $1; exit}')"
fi
if [ -z "$ADAPTER" ] || ! ip -br link | awk '{print $1}' | grep -qx "$ADAPTER"; then
    c_bad "Wireless adapter not found${ADAPTER:+: $ADAPTER}"
    c_note "Available interfaces:"
    ip -br link | awk '{print "      " $1, $3}'
    c_note "Set one explicitly:  ADAPTER=wlan0 ./scripts/flash.sh"
    exit 1
fi
c_ok "Adapter $ADAPTER is present"

if ! iw dev "$ADAPTER" info >/dev/null 2>&1; then
    c_bad "'$ADAPTER' is not a WiFi (nl80211) interface."
    exit 1
fi

PHY="phy$(iw dev "$ADAPTER" info | awk '/wiphy/ {print $2; exit}')"
if iw phy "$PHY" info 2>/dev/null | grep -A20 'Supported interface modes' | grep -qw 'AP'; then
    c_ok "$PHY supports AP mode (required)"
else
    c_bad "$PHY does NOT advertise AP mode. Cloudcutter cannot work."
    exit 1
fi

if [ -f "$CLOUDCUTTER_DIR/device-profiles/$PROFILE/profile.json" ] \
   && [ -f "$CLOUDCUTTER_DIR/device-profiles/$PROFILE/combined.json" ]; then
    c_ok "Device profile cached (offline ready)"
else
    c_bad "Profile cache missing or incomplete: $PROFILE"
    c_note "Expected at: $CLOUDCUTTER_DIR/device-profiles/$PROFILE/"
    c_note "Run: ./scripts/prepare-offline.sh (while online)"
    exit 1
fi

if [ -f "$CLOUDCUTTER_DIR/custom-firmware/$FWFILE" ]; then
    c_ok "Firmware present"
else
    c_bad "Firmware missing: $FWFILE"
    c_note "Expected at: $CLOUDCUTTER_DIR/custom-firmware/$FWFILE"
    exit 1
fi

if [ -n "$(docker images cloudcutter:latest --format '{{.Size}}' 2>/dev/null)" ]; then
    c_ok "Docker image built"
else
    c_bad "Docker image missing."
    c_note "Run:  cd $CLOUDCUTTER_DIR && docker build -t cloudcutter ."
    exit 1
fi

NO_NET="no"
if ip -br link | awk '$1 ~ /^(eth|enp|eno|ens|enx)/ {found=1} END {exit !found}'; then
    c_ok "Wired ethernet present - your network will survive"
else
    c_warn "NO wired ethernet. Your network WILL drop during the flash."
    c_note "This is fine if you are at the laptop's own console."
    NO_NET="yes"
fi

echo
echo "All checks passed."
if [ "$NO_NET" = "yes" ]; then
    printf '\n\033[33mWhen the flash starts this machine goes offline and takes any\n'
    printf 'remote session with it. Keep the terminal open.\033[0m\n'
fi

# ---------------------------------------------------------------------------
c_hdr "STEP 2 of 4 - Put the blaster into AP mode"
# ---------------------------------------------------------------------------
echo "The device must be broadcasting its setup AP before we start."
echo
echo "  1. Power the blaster from USB."
echo "  2. Toggle power OFF/ON 6 times, about 1 second apart."
echo "     (Some units use the button: hold ~5 s, release, hold again.)"
echo "  3. The LED should blink SLOWLY, and a SmartLife-XXXX AP should appear."
echo "       - Fast blink? Power-cycle 3 more times."
echo
read -rp "Is the LED blinking slowly right now? [y/N] " ans
case "$ans" in
    [yY]*) ;;
    *) echo; echo "Power-cycle it, then re-run. Nothing was changed."; exit 1;;
esac

# ---------------------------------------------------------------------------
c_hdr "STEP 3 of 4 - Flashing"
# ---------------------------------------------------------------------------
echo "About to run:"
echo
echo "    cd $CLOUDCUTTER_DIR"
echo "    sudo ./tuya-cloudcutter.sh -w $ADAPTER -p $PROFILE -f $FWFILE"
echo
echo "What happens next:"
echo "  - cloudcutter scans for the device's SmartLife AP and exploits it."
echo "  - It brings up its own AP called 'cloudcutterflash'."
echo "  - You will be asked to power-cycle the device ONCE more."
echo "  - The device joins cloudcutterflash and receives the new firmware."
echo
printf '\033[31mYOUR NETWORK MAY DROP NOW. This is expected.\033[0m\n'
echo
read -rp "Ready to flash? Type 'flash' to continue: " go
if [ "$go" != "flash" ]; then
    echo "Aborted. Nothing was changed."
    exit 1
fi

cd "$CLOUDCUTTER_DIR" || exit 1
sudo ./tuya-cloudcutter.sh -w "$ADAPTER" -p "$PROFILE" -f "$FWFILE"
RC=$?

echo
echo "=============================================================="
echo " FLASH SCRIPT FINISHED (exit code $RC)"
echo "=============================================================="
echo
echo "Success looks like 'Firmware update sent' near the end of the output."
echo

# ---------------------------------------------------------------------------
c_hdr "STEP 4 of 4 - What to do now"
# ---------------------------------------------------------------------------
cat <<'EOS'
  A. JOIN THE KICKSTART ACCESS POINT
     - The blaster now boots ESPHome Kickstart.
     - It broadcasts an open AP named  kickstart-bk7231n-tuya  (no password).
     - Connect to it from your phone or laptop.

  B. CAPTIVE PORTAL
     - A config page should pop up automatically.
     - If not, browse to:   http://192.168.4.1
     - Enter your 2.4 GHz WiFi SSID and password so the blaster joins your LAN.

  C. FLASH THE REAL FIRMWARE OVER THE AIR
     - Find the device IP in your router, or use its .local name.
     - From this repo:

           cp examples/blaster.yaml ~/esphome/
           cp examples/secrets.yaml.example ~/esphome/secrets.yaml  # edit it
           cp -r components/sh4_rf ~/esphome/components/

           cd ~/esphome
           esphome compile blaster.yaml
           esphome upload blaster.yaml --device <device-ip>

     - All future updates are OTA. There is no serial header on this board,
       so keep wifi:, ota: and the fallback ap: in the config.

  D. PINS ARE ALREADY KNOWN (no pin hunt needed)
     - IR TX      P7
     - Status LED P9
     - RF RX      P20  (CMT2300A DOUT, direct mode)
     - SPI        SCLK P14, SDIO P16, CSB P6, FCSB P26
     - RF TX uses the CMT2300A packet/FIFO engine, so no DIN pin is needed.

  E. LEARN AND REPLAY
     - In Home Assistant: press "Learn Slot 1", tap the remote once,
       then press "Send Slot 1".
     - Replay is inverted and sends exactly one frame; see docs/.

  If the flash failed, or the device never came back: unplug it, put it back
  into slow-blink AP mode, and re-run this script. Cloudcutter can only exploit
  the stock Tuya firmware, so once ESPHome is running, use OTA.
EOS
