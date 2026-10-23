#!/usr/bin/env bash
#
# prepare-offline.sh - download and build everything the flash needs, so that
#                      the actual flash step can run with no internet.
#
# Run this once, while online. It does NOT touch the radio or the device.
#
# What it does:
#   1. checks host dependencies (docker, git, curl, python3, iw)
#   2. clones tuya-cloudcutter at a pinned commit
#   3. builds the cloudcutter docker image
#   4. downloads the ESPHome Kickstart firmware for BK7231N
#   5. caches the device profile + combined.json for this blaster
#
# After it succeeds, `scripts/flash.sh` works offline (cloudcutter itself is
# run with --network none by its wrapper).
#
# Usage:
#   ./scripts/prepare-offline.sh
#   REBUILD=1 ./scripts/prepare-offline.sh   # rebuild the docker image
#
# Environment:
#   CLOUDCUTTER_DIR  default: ~/tuya-cloudcutter
#   DEVICE_SLUG      default: tuya-generic-ir-rf-universal-remote-controller-v2.0.8
#   PROFILE_SLUG     default: oem-bk7231n-smart-ir-rf-pro-ty-2.0.8-sdk-2.3.1-40.00
#   FWFILE           default: kickstart-bk7231n-tuya-2026-10-06.ota.ug.bin
#   CC_COMMIT        default: b5712802c4cc0668a8db8434b7fef94bda8d40e5
#
set -euo pipefail

CLOUDCUTTER_DIR="${CLOUDCUTTER_DIR:-$HOME/tuya-cloudcutter}"
DEVICE_SLUG="${DEVICE_SLUG:-tuya-generic-ir-rf-universal-remote-controller-v2.0.8}"
PROFILE_SLUG="${PROFILE_SLUG:-oem-bk7231n-smart-ir-rf-pro-ty-2.0.8-sdk-2.3.1-40.00}"
FWFILE="${FWFILE:-kickstart-bk7231n-tuya-2026-10-06.ota.ug.bin}"
CC_COMMIT="${CC_COMMIT:-b5712802c4cc0668a8db8434b7fef94bda8d40e5}"
API="https://tuya-cloudcutter.github.io/api"
FW_URL="https://github.com/libretiny-eu/esphome-kickstart/releases/download/v26.10.06/$FWFILE"

ok()   { printf '  \033[32m[ OK ]\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; }
note() { printf '         %s\n' "$1"; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

echo "=============================================================="
echo " PREPARE OFFLINE FLASH KIT"
echo " Device profile: $DEVICE_SLUG"
echo " Firmware      : $FWFILE"
echo "=============================================================="

# ---------------------------------------------------------------------------
hdr "1. Host dependencies"
# ---------------------------------------------------------------------------
MISSING=0
for c in docker git curl python3; do
    if command -v "$c" >/dev/null 2>&1; then
        ok "$c present"
    else
        bad "$c MISSING"
        MISSING=1
    fi
done
if command -v iw >/dev/null 2>&1; then
    ok "iw present"
else
    bad "iw MISSING (cloudcutter needs it on the host)"
    note "Install:  sudo apt install -y iw"
    MISSING=1
fi
if [ "$MISSING" -ne 0 ]; then
    echo
    echo "Install the missing packages above, then re-run."
    exit 1
fi

# ---------------------------------------------------------------------------
hdr "2. tuya-cloudcutter"
# ---------------------------------------------------------------------------
if [ -d "$CLOUDCUTTER_DIR/.git" ]; then
    ok "repo exists: $CLOUDCUTTER_DIR"
    CUR="$(git -C "$CLOUDCUTTER_DIR" rev-parse HEAD)"
    if [ "$CUR" = "$CC_COMMIT" ]; then
        ok "at pinned commit ${CC_COMMIT:0:7}"
    else
        note "currently ${CUR:0:7}; this project was tested with ${CC_COMMIT:0:7}"
        note "Set CC_COMMIT=$CUR to keep your checkout, or 'git checkout $CC_COMMIT'."
    fi
else
    note "cloning into $CLOUDCUTTER_DIR ..."
    git clone https://github.com/tuya-cloudcutter/tuya-cloudcutter "$CLOUDCUTTER_DIR"
    git -C "$CLOUDCUTTER_DIR" checkout -q "$CC_COMMIT"
    ok "cloned at ${CC_COMMIT:0:7}"
fi

# ---------------------------------------------------------------------------
hdr "3. Docker image"
# ---------------------------------------------------------------------------
if [ "${REBUILD:-0}" != "1" ] && [ -n "$(docker images cloudcutter:latest --format '{{.Size}}' 2>/dev/null)" ]; then
    ok "cloudcutter:latest already built"
else
    note "building cloudcutter:latest (first build takes a few minutes) ..."
    docker build -t cloudcutter "$CLOUDCUTTER_DIR"
    ok "cloudcutter:latest built"
fi

# ---------------------------------------------------------------------------
hdr "4. Kickstart firmware"
# ---------------------------------------------------------------------------
mkdir -p "$CLOUDCUTTER_DIR/custom-firmware"
FW_PATH="$CLOUDCUTTER_DIR/custom-firmware/$FWFILE"
if [ -f "$FW_PATH" ]; then
    ok "firmware already present"
else
    note "downloading $FWFILE ..."
    curl -fL --retry 3 --retry-delay 2 -o "$FW_PATH.part" "$FW_URL"
    mv "$FW_PATH.part" "$FW_PATH"
    ok "downloaded"
fi
MAGIC="$(xxd -l 4 -p "$FW_PATH" 2>/dev/null || true)"
if [ "$MAGIC" = "55aa55aa" ]; then
    ok "valid Tuya UG image ($(stat -c%s "$FW_PATH") bytes)"
else
    bad "unexpected firmware magic: ${MAGIC:-<unreadable>}"
    note "Expected 55aa55aa. Delete $FW_PATH and re-run."
    exit 1
fi

# ---------------------------------------------------------------------------
hdr "5. Device profile (for offline use)"
# ---------------------------------------------------------------------------
PROFILE_DIR="$CLOUDCUTTER_DIR/device-profiles/$DEVICE_SLUG"
mkdir -p "$PROFILE_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ ! -s "$PROFILE_DIR/device.json" ]; then
    curl -fsSL -o "$TMP/device.json" "$API/devices/$DEVICE_SLUG.json"
    mv "$TMP/device.json" "$PROFILE_DIR/device.json"
    ok "device.json downloaded"
else
    ok "device.json already cached"
fi

if [ ! -s "$PROFILE_DIR/profile.json" ]; then
    curl -fsSL -o "$TMP/profile.json" "$API/profiles/$PROFILE_SLUG.json"
    mv "$TMP/profile.json" "$PROFILE_DIR/profile.json"
    ok "profile.json downloaded"
else
    ok "profile.json already cached"
fi

# combined.json is what the container consumes: {slug, device, profile}
python3 - "$PROFILE_DIR" <<'PY'
import json, os, sys
d = sys.argv[1]
with open(os.path.join(d, "device.json")) as f:
    device = json.load(f)
with open(os.path.join(d, "profile.json")) as f:
    profile = json.load(f)
combined = {"slug": os.path.basename(d), "device": device, "profile": profile}
tmp = os.path.join(d, "combined.json.tmp")
with open(tmp, "w") as f:
    json.dump(combined, f, indent="\t")
os.replace(tmp, os.path.join(d, "combined.json"))
print("  \033[32m[ OK ]\033[0m combined.json written")
PY

CHIP="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['firmware']['chip'])" "$PROFILE_DIR/profile.json")"
if [ "$CHIP" = "BK7231N" ]; then
    ok "profile targets BK7231N"
else
    bad "profile targets $CHIP, expected BK7231N"
    exit 1
fi

# ---------------------------------------------------------------------------
hdr "Ready"
# ---------------------------------------------------------------------------
echo
echo "Everything needed for the flash is cached locally:"
echo "  cloudcutter image : cloudcutter:latest"
echo "  firmware          : $FW_PATH"
echo "  profile           : $PROFILE_DIR"
echo
echo "Next:"
echo "  ./scripts/preflight.sh    # safe checks, run any time"
echo "  ./scripts/flash.sh        # the actual flash (may drop your network)"
