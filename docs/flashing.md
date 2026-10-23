# Flashing

The BK7231N can be flashed **without opening the case or soldering**, using
Tuya's own cloud API to install a community firmware. The tool is
[tuya-cloudcutter](https://github.com/tuya-cloudcutter/tuya-cloudcutter).

> There is no serial header exposed. Once the device runs ESPHome, all further
> updates are OTA. Keep a working OTA path.

## Prerequisites

- Linux or macOS (cloudcutter ships as a Docker image).
- A **2.4 GHz** Wi-Fi network. The BK7231N cannot see 5 GHz networks.
- The device powered by USB and reachable.
- About 15 minutes.
- **Wired ethernet or a local console.** cloudcutter moves the Wi-Fi adapter
  into its container, so Wi-Fi on the host drops during the flash.

## Offline flash kit (recommended)

The repo ships three scripts that replace the manual cloudcutter walk-through:

| Script | When | Network |
|--------|------|---------|
| `scripts/prepare-offline.sh` | once, before anything | online |
| `scripts/preflight.sh` | any time; safe, read-only | any |
| `scripts/flash.sh` | the actual flash | offline once prepared |

```sh
git clone <this repo>
cd tuya-ir-rf-blaster

./scripts/prepare-offline.sh   # clone cloudcutter, build image, cache profile + firmware
./scripts/preflight.sh         # verify adapter/AP mode, image, profile, firmware
./scripts/flash.sh             # from the machine's own console
```

`prepare-offline.sh` pins tuya-cloudcutter to the commit this project was tested
with, builds `cloudcutter:latest`, downloads the BK7231N Kickstart image, and
caches the device profile plus `combined.json`. After that the flash needs no
internet. Both `prepare-offline.sh` and `preflight.sh` are idempotent.

`flash.sh` auto-detects the wireless adapter (`ADAPTER=wlan0` to override),
refuses to run over SSH without ethernet, checks that the adapter supports AP
mode, walks you through AP mode, then runs:

```sh
sudo ./tuya-cloudcutter.sh -w "$ADAPTER" -p "$PROFILE" -f "$FWFILE"
```

## Step 1 — Identify the device profile

The profile used here is:

```
tuya-generic-ir-rf-universal-remote-controller-v2.0.8
  → oem-bk7231n-smart-ir-rf-pro-ty-2.0.8-sdk-2.3.1-40.00
  → chip: BK7231N
```

To find it manually, put the device into pairing mode (power-cycle 6 times, or
hold the button ~5 s until the LED blinks), then pick the matching entry in
cloudcutter. The important part is that the SoC is a **BK7231N** and the ESPHome
board target is `generic-bk7231n-qfn32-tuya`.

## Step 2 — Flash the ESPHome kickstart image

`flash.sh` does this for you. Manually, choose the **ESPHome Kickstart**
firmware when cloudcutter asks: a minimal ESPHome build whose only job is to get
on Wi-Fi and expose OTA.

cloudcutter will:

1. Exploit the Tuya cloud handshake to get the device to accept a firmware URL.
2. Download and flash the kickstart image.
3. Reboot into ESPHome.

## Step 3 — Join Wi-Fi

After the flash the device starts a fallback AP (e.g. `ir-rf-blaster` or the
name compiled into the kickstart image).

1. Connect to that AP.
2. Open `http://192.168.4.1` (captive portal).
3. Enter your 2.4 GHz SSID and password.
4. The device reboots onto your network.

Find its IP in your router's DHCP table, or use `ir-rf-blaster.local`.

## Step 4 — Install this configuration

```sh
git clone <this repo>
cd tuya-ir-rf-blaster

# copy the component and example config into your ESPHome directory
cp -r components/sh4_rf ~/esphome/components/
cp examples/blaster.yaml ~/esphome/
cp examples/secrets.yaml.example ~/esphome/secrets.yaml   # edit it

cd ~/esphome
esphome compile blaster.yaml
esphome upload blaster.yaml --device <device-ip>
```

From this point on, updates are OTA:

```sh
esphome upload blaster.yaml --device <device-ip>
```

## Recovery

- **Device unreachable / fallback AP:** power-cycle it. If it still boots into
  the fallback AP, reconnect and re-enter Wi-Fi credentials.
- **Bad firmware that still boots Wi-Fi:** OTA again with a known-good config.
- **Bad firmware that does not boot Wi-Fi:** the BK7231N bootloader can be
  reached over UART, but that requires opening the case. Avoid this by testing
  configs that keep `ota:` and `wifi:` intact.

## Notes

- `api: reboot_timeout: 0s` keeps the API up even if Home Assistant is offline.
- Leave `captive_portal:` and the `ap:` fallback in place; they are your safety
  net.
- The initial cloudcutter flash can be repeated if needed, but it requires the
  device to be in pairing mode again.
