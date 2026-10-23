#!/usr/bin/env bash
#
# preflight.sh - safe, non-destructive checks before flashing.
#
# This never touches the WiFi adapter and never takes you offline, so it is
# safe to run repeatedly and over SSH.
#
# Checks:
#   1. local console vs remote session
#   2. host tools (docker, git, curl, python3, iw)
#   3. cloudcutter docker image
#   4. cached device profile (offline ready)
#   5. kickstart firmware (present + valid UG magic)
#   6. WiFi adapter and AP-mode support
#   7. ESPHome toolchain (only needed after the flash)
#
# Exit code: 0 if no FAIL items, 1 otherwise.
#
set -u

CLOUDCUTTER_DIR="${CLOUDCUTTER_DIR:-$HOME/tuya-cloudcutter}"
DEVICE_SLUG="${DEVICE_SLUG:-tuya-generic-ir-rf-universal-remote-controller-v2.0.8}"
FWFILE="${FWFILE:-kickstart-bk7231n-tuya-2026-10-06.ota.ug.bin}"
ESPHOME_BIN="${ESPHOME_BIN:-esphome}"

PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[32m[ OK ]\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33m[WARN]\033[0m %s\n' "$1"; WARN=$((WARN+1)); }
note() { printf '         %s\n' "$1"; }

echo
echo "=============================================================="
echo " TUYA BLASTER - PRE-FLIGHT CHECKS (safe, nothing destructive)"
echo "=============================================================="

# ---- 1. Local console -------------------------------------------------
echo
echo "[1] Console check (the #1 cause of a botched run)"
# A local tmux session survives a network drop. Only a REMOTE session is a
# problem, because the flash takes the WiFi adapter offline mid-write.
if [ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ] && [ -z "${FORCE_LOCAL:-}" ]; then
    bad "You are in an SSH session."
    note "The flash MOVES the WiFi adapter into a container. Your network dies,"
    note "which kills SSH mid-flash and can leave the device half-written."
    note "Run the flash from the machine's own screen and keyboard."
    note "(Set FORCE_LOCAL=1 to acknowledge and continue.)"
else
    ok "Local session (not remote)."
fi
if ip -br link 2>/dev/null | grep -q tailscale; then
    warn "Tailscale is up. It rides over the same WiFi, so it WILL drop too."
fi

# ---- 2. Tools ---------------------------------------------------------
echo
echo "[2] Tools and repo"
for c in docker git curl python3; do
    if command -v "$c" >/dev/null 2>&1; then ok "$c present"; else bad "$c MISSING"; fi
done
if command -v iw >/dev/null 2>&1; then
    ok "iw present (cloudcutter hard-requires it on the host)"
else
    bad "iw MISSING. Install it:  sudo apt install -y iw"
    note "This is the only extra package needed."
fi
if [ -d "$CLOUDCUTTER_DIR" ]; then
    ok "$CLOUDCUTTER_DIR exists"
else
    bad "$CLOUDCUTTER_DIR MISSING (run scripts/prepare-offline.sh)"
fi

# ---- 3. Docker image --------------------------------------------------
echo
echo "[3] Docker image (pre-built so the flash needs no internet)"
if [ -n "$(docker images cloudcutter:latest --format '{{.Size}}' 2>/dev/null)" ]; then
    ok "cloudcutter:latest built ($(docker images cloudcutter:latest --format '{{.Size}}'))"
else
    bad "cloudcutter image missing - run scripts/prepare-offline.sh"
fi

# ---- 4. Profile -------------------------------------------------------
echo
echo "[4] Device profile cached (offline ready)"
PROFILE_DIR="$CLOUDCUTTER_DIR/device-profiles/$DEVICE_SLUG"
if [ -f "$PROFILE_DIR/profile.json" ] && [ -f "$PROFILE_DIR/combined.json" ]; then
    ok "profile cached: $DEVICE_SLUG"
    CHIP="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['firmware']['chip'])" \
            "$PROFILE_DIR/profile.json" 2>/dev/null || true)"
    if [ "$CHIP" = "BK7231N" ]; then
        ok "chip = BK7231N (matches generic-bk7231n-qfn32-tuya)"
    else
        warn "chip = ${CHIP:-unknown}"
    fi
else
    bad "profile not cached - the flash would need internet"
    note "Run scripts/prepare-offline.sh while online."
fi

# ---- 5. Firmware ------------------------------------------------------
echo
echo "[5] Firmware to flash (ESPHome Kickstart - pin scanner, zero compile)"
FW_PATH="$CLOUDCUTTER_DIR/custom-firmware/$FWFILE"
if [ -f "$FW_PATH" ]; then
    MAGIC="$(xxd -l 4 -p "$FW_PATH" 2>/dev/null || true)"
    if [ "$MAGIC" = "55aa55aa" ]; then
        ok "$FWFILE ($(stat -c%s "$FW_PATH") bytes, valid UG magic)"
    else
        bad "$FWFILE has bad magic (${MAGIC:-unreadable})"
    fi
else
    bad "$FWFILE missing from custom-firmware/"
fi

# ---- 6. Adapter -------------------------------------------------------
echo
echo "[6] WiFi adapter and AP mode (the make-or-break check)"
ADAPTER="${ADAPTER:-}"
if [ -z "$ADAPTER" ]; then
    ADAPTER="$(ip -br link 2>/dev/null | awk '$1 ~ /^(wl|wlan|wifi)/ {print $1; exit}')"
fi
if [ -n "$ADAPTER" ]; then
    ok "candidate adapter: $ADAPTER"
    if command -v iw >/dev/null 2>&1; then
        PHY="phy$(iw dev "$ADAPTER" info 2>/dev/null | awk '/wiphy/ {print $2; exit}')"
        if iw phy "$PHY" info 2>/dev/null | grep -A20 'Supported interface modes' | grep -qw 'AP'; then
            ok "AP mode supported on $PHY"
        else
            bad "AP mode NOT supported on $PHY - cloudcutter cannot work"
        fi
    else
        note "(iw not installed, skipping live AP test)"
    fi
else
    bad "no WiFi adapter found (set ADAPTER=...)"
fi

if ip -br link 2>/dev/null | awk '$1 ~ /^(eth|enp|eno|ens|enx)/ {found=1} END {exit !found}'; then
    ok "wired ethernet present - your network survives the flash"
else
    warn "NO wired ethernet. The flash WILL drop this machine's network."
    note "Run it from the machine's own console, or add USB/phone tethering."
fi

# ---- 7. ESPHome -------------------------------------------------------
echo
echo "[7] ESPHome (for the post-flash OTA, not needed for the flash itself)"
if ! command -v "$ESPHOME_BIN" >/dev/null 2>&1 && [ -x "$HOME/.esphome-venv/bin/esphome" ]; then
    ESPHOME_BIN="$HOME/.esphome-venv/bin/esphome"
fi
if command -v "$ESPHOME_BIN" >/dev/null 2>&1; then
    ok "$("$ESPHOME_BIN" version 2>/dev/null | head -1)"
else
    warn "esphome not found - install it before the OTA step"
fi

# ---- summary ----------------------------------------------------------
echo
echo "=============================================================="
echo " RESULT: $PASS ok, $WARN warn, $FAIL fail"
echo "=============================================================="
if [ "$FAIL" -gt 0 ]; then
    echo
    echo "Fix the FAIL items above, then re-run."
    exit 1
fi
echo
echo "Everything needed is cached locally. You are ready for the flash."
echo "Reminder: the flash step should run from the machine's own console."
