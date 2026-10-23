# Tuya IR + RF Blaster → ESPHome

> **AI-assisted project.** This repo is the result of an AI exploration run with
> [OpenCode](https://opencode.ai) and DeepSeek. The findings were verified on
> real hardware (RF captures, OTA flashes, repeated replays), but treat the code
> and docs as a well-tested starting point rather than an official product.
> Corrections and issue reports are welcome.

Turn a cheap Tuya "IR + RF" blaster into a fully local ESPHome device with
**IR transmit**, **433.92 MHz RF receive**, and **433.92 MHz RF transmit**
(raw record & replay) — entirely over the air. No soldering, no serial, no
cloud.

This repo documents the device, the flashing process, the ESPHome component,
and the register-level details that make RF transmit work on this hardware.

```
Device   Tuya IR+RF blaster (ASIN B0D926FQRQ), BK7231N
RF chip  CMT2300A inside the Tuya "SH4" module, 433.92 MHz OOK
Firmware ESPHome (bk72xx / LibreTiny)
Status   working, used daily through Home Assistant
```

## Why this repo exists

Flashing BK7231N IR blasters is well covered. The CMT2300A's RX side is
documented. What is *not* documented is **transmitting** from this module:
the stock register dump is a direct-mode configuration that keys the PA from a
GPIO pin which is not usable from the host, so a naive port produces a chip that
reports correct TX airtime while radiating nothing.

The short version: **use the packet/FIFO engine, and check three register bits**
(see [docs/rf-reverse-engineering.md](docs/rf-reverse-engineering.md)).

## Features

| Feature | Status | Notes |
|---------|--------|-------|
| IR transmit | ✅ | stock `remote_transmitter` on P7 |
| RF receive | ✅ | CMT2300A direct mode, DOUT on P20 |
| RF transmit | ✅ | packet/FIFO mode, raw replay |
| Learn & replay from HA | ✅ | 6 persistent slots, no recompile |
| Native HA IR/RF entities | ✅ | `infrared` (HA 2026.4+) and `radio_frequency` (HA 2026.5+) |
| OTA updates | ✅ | after the initial cloudcutter flash |

## Quick start

1. **Prepare the offline flash kit** (once, while online):

   ```sh
   ./scripts/prepare-offline.sh   # clones cloudcutter, builds image, caches profile + firmware
   ./scripts/preflight.sh         # safe checks: adapter, AP mode, image, profile, firmware
   ```

2. **Flash** the device with [tuya-cloudcutter](https://github.com/tuya-cloudcutter/tuya-cloudcutter)
   using the ESPHome Kickstart firmware:

   ```sh
   ./scripts/flash.sh             # from the machine's own console
   ```

   See [docs/flashing.md](docs/flashing.md) for the manual walk-through and
   recovery notes.

3. Copy `components/sh4_rf/` into your ESPHome config directory.
4. Start from [examples/blaster.yaml](examples/blaster.yaml) and
   [examples/secrets.yaml.example](examples/secrets.yaml.example).
5. Compile and upload. From then on everything is OTA.
6. Learn a remote button (press `Learn Slot 1`, then tap the remote), then
   press `Send Slot 1`. See [docs/home-assistant.md](docs/home-assistant.md).

## Repository layout

```
scripts/prepare-offline.sh   one-time: cache everything the flash needs
scripts/preflight.sh         safe checks before flashing
scripts/flash.sh             cloudcutter flash, offline-capable
components/sh4_rf/     ESPHome external component (CMT2300A driver, RX + TX)
docs/device.md         what the hardware is and how to identify it
docs/flashing.md       cloudcutter → ESPHome, step by step
docs/rf-reverse-engineering.md   CMT2300A registers, framing, TX recipe
docs/component.md      component configuration and API reference
docs/home-assistant.md entities, learn/replay, automations
examples/              a working ESPHome config (sanitised)
AGENTS.md              condensed field notes / gotchas
```

## The five rules for RF TX

1. **Frame length matters.** Capture the *whole* burst. A truncated frame is
   silently ignored by the receiver. (Ours is 132 raw elements, ~84 ms.)
2. **Source the modulation from the FIFO**, not the DIN pin:
   `PKT1 0x38 = 0x02`, `TX1 0x55` bit 2 = 0 (`0x51`),
   `FIFO_CTL 0x69` bit 7 = 0 (`0x05`).
3. **Check polarity.** The direct-mode DOUT on this module reports carrier as
   *low*, so captured "marks" must be replayed **inverted**.
4. **Send one repeat.** One frame = one button press. Extra repeats toggle the
   target multiple times.
5. **Use the chip's native bit rate.** Measure it (~417 µs here) instead of
   assuming; changing `DR_M` breaks TX.

## Prior art

- [tuya-cloudcutter](https://github.com/tuya-cloudcutter/tuya-cloudcutter) —
  flashing BK7231 devices without serial.
- [ESPHome bk72xx](https://esphome.io/components/bk72xx.html) — LibreTiny
  support.
- [anisyanka/cmt2300a](https://github.com/anisyanka/cmt2300a) — clean CMT2300A
  driver used as a register/FIFO reference.
- [sillyfrog/RFreplayESP](https://github.com/sillyfrog/RFreplayESP) — the
  record-and-replay approach for 433 MHz remotes.
- CMOSTEK/HOPERF CMT2300A datasheet and AN143 (FIFO and packet format).

## Disclaimer

Not affiliated with Tuya. Flashing custom firmware voids warranties and can
brick a device (OTA recovery is possible but not guaranteed). RF regulations are
your responsibility: only replay signals you are allowed to transmit, and keep
within your local power/duty-cycle limits.
