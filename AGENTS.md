# Agent / contributor notes

Read these before changing the RF path. Everything here was verified on real
hardware; the failure modes are silent, so a plausible-looking change can stop
working with no error.

## Non-negotiables

1. **Capture and replay the whole burst.** The reference remote produces 132 raw
   elements (~84 ms), which quantise to 208 bits / 26 bytes. A truncated frame
   (e.g. 43 elements) is accepted by the radio and ignored by the receiver.
   Verify with two separate captures.
2. **TX data source = FIFO, in three places.**
   `PKT1 0x38 = 0x02`, `TX1 0x55` bit2 = 0 (`0x51`),
   `FIFO_CTL 0x69` bit7 = 0 (`0x05`).
   The stock Tuya dump is direct mode (`TX1 = 0x55`); copying it verbatim keys
   the PA from an undriven DIN pin. Airtime still looks correct.
3. **Replay inverted.** The direct-mode DOUT reports carrier as low, so captured
   marks are gaps on air. `send_fifo_auto(..., invert = true)`.
4. **One repeat.** The target counts every valid frame as a press. Multiple reps
   toggle it multiple times.
5. **Never change the bit rate via `DR_M` (0x20-0x22).** It collapsed TX to
   ~12 us. Measure the native rate (4-byte vs 16-byte airtime, ~417 us) and
   encode at that.

## Storage rule

Learned frames are stored **quantised as hex**, not as a raw CSV. ESPHome string
globals persist at most 254 bytes (`max_restore_data_length`), and a raw capture
is 600-1700 bytes, so it would silently restore as an empty string.

## Receiver rules

- Learn slicing is `x[start .. end-1]`: `end` is exclusive. An off-by-one drops
  the last element and replay fails.
- Compare `std::abs()` when looking for the 50 ms end pulse; it can be negative.
- Do not poll the RX pin with `digitalRead()`; it reconfigures the pad. The
  component timestamps edges in an ISR.

## Diagnostics that lie

- TX airtime scaling with payload length proves the packet engine is counting
  bits, **not** that the PA is modulated.
- `gpio_selftest` readback is unreliable on output pins.
- A CW jam test is meaningless unless the FIFO source bits are already correct.

## Layout

```
scripts/prepare-offline.sh  cache cloudcutter image + profile + firmware (online, once)
scripts/preflight.sh        safe checks (never touches the adapter)
scripts/flash.sh            cloudcutter flash (drops host Wi-Fi)
components/sh4_rf/          driver: SPI, RX ISR, packet TX, diagnostics
examples/blaster.yaml       working config with learn/replay
docs/                       device, flashing, RF theory, component API, HA usage
```

## Flashing rules

- Prepare while online; flash offline. `prepare-offline.sh` pins cloudcutter to
  the tested commit and caches the profile, firmware and Docker image.
- Run `flash.sh` from the machine's own console, or with wired ethernet. The
  container takes the Wi-Fi adapter, so SSH over Wi-Fi dies mid-write.
- The profile is device-specific:
  `tuya-generic-ir-rf-universal-remote-controller-v2.0.8` (BK7231N).

## Build

```sh
esphome compile examples/blaster.yaml   # after copying secrets.yaml
esphome upload examples/blaster.yaml --device <ip>
```

Keep `ota:`, `wifi:` and the fallback `ap:` intact in any config you flash;
there is no exposed serial header.
