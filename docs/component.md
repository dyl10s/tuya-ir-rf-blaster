# `sh4_rf` component reference

An ESPHome external component for the Tuya SH4 / CMT2300A module. It provides:

- RF **receive** in direct mode, integrated with ESPHome's `remote_base`
  (`on_raw`, `dump:`, `remote_receiver`-style triggers).
- RF **transmit** in packet/FIFO mode, with runtime bit-rate calibration and
  polarity inversion.
- IR is *not* part of this component; use the standard `remote_transmitter`.

## Installation

```yaml
external_components:
  - source:
      type: local
      path: components
    components: [sh4_rf]
```

Copy `components/sh4_rf/` next to your YAML. Requires an ESPHome version with
the 2026.x `remote_base` API (`build_dumpers` / `build_triggers` / `add_listener`).

## Configuration

```yaml
sh4_rf:
  id: rf
  spi_enabled: true
  sclk_pin: P14
  sdio_pin: P16
  csb_pin: P6
  fcsb_pin: P26
  rx_pin: P20
  tx_on_rx_pin: true
  rx_mode: direct
  dump: [raw, rc_switch]
  filter: 50us
  tolerance: 25%
  start_pulse_min: 4ms
  start_pulse_max: 12ms
  end_pulse: 50ms
  buffer_size: 2000
  on_raw:
    then:
      - lambda: |-
          // x is a std::vector<int32_t> of raw timings, in microseconds
```

| Option | Default | Description |
|--------|---------|-------------|
| `spi_enabled` | `true` | drive the CMT2300A over bit-banged SPI |
| `sclk_pin` | — | SPI clock |
| `sdio_pin` | — | bidirectional SPI data |
| `csb_pin` | **required** | register chip select |
| `fcsb_pin` | **required** | FIFO chip select |
| `rx_pin` | **required** | demodulated data input (DOUT) |
| `tx_pin` | — | direct-mode DIN output (unused in packet mode) |
| `tx_on_rx_pin` | `false` | use `rx_pin` as `tx_pin` |
| `tx_pin_alt` | — | alternate direct-mode pin |
| `tx_din_gpio` | `1` | CMT2300A GPIO1/2/3 used as DIN in direct mode |
| `tx_din_invert` | `false` | invert direct-mode DIN |
| `tx_fcsb_low` | `false` | keep FCSB low between bytes |
| `rx_mode` | `direct` | `direct` (GPIO pulses) or `fifo` (packet RX) |
| `receiver_disabled` | `false` | start with the receiver off |
| `buffer_size` | `1000` | ISR ring buffer entries |
| `filter` | `50us` | ignore pulses shorter than this |
| `tolerance` | `25%` | `remote_base` tolerance |
| `dump` | `[]` | `raw`, `rc_switch`, … |
| `start_pulse_min` | `6ms` | minimum sync pulse |
| `start_pulse_max` | `10ms` | maximum sync pulse |
| `end_pulse` | `50ms` | silence that ends a frame |
| `scan_pins` | `[]` | extra pins for the diagnostic GPIO scan |
| `led_pin` | — | status LED |
| `on_raw` | — | trigger fired with the raw timing vector |

Notes:

- `start_pulse_min`/`max` are matched against the **sync** pulse. The Hunter
  remote's sync is ~4.8 ms, hence `4ms`/`12ms` in the example.
- `end_pulse` also defines how long the receiver waits before publishing a
  frame. Shorter = faster feedback, but must be longer than the gap between
  repeats you want to merge.

## Actions

```yaml
- sh4_rf.turn_off_receiver: rf
- sh4_rf.turn_on_receiver: rf
- sh4_rf.set_rx_mode:
    id: rf
    mode: fifo
```

## Lambda API

```cpp
// Working TX path: calibrate bit rate, encode, send N frames.
// invert = true is what this hardware needs (see rf-reverse-engineering.md).
id(rf).send_fifo_auto(timings, /*reps=*/1, /*invert=*/true);

// Legacy: fixed bit period, no calibration.
id(rf).send_fifo(timings, /*reps=*/8, /*bit_us=*/315);

// Diagnostics
id(rf).cw_test(30);                 // 30 s unmodulated carrier (jams the band)
id(rf).fifo_scan();                 // dump FIFO/register state
id(rf).rf_marathon(timings, 180);   // retry both polarities for 3 minutes
id(rf).identify(3);                 // blink the status LED
```

`timings` is `remote_base::RawTimings` (`std::vector<int32_t>`): positive =
carrier on, negative = carrier off, values in microseconds.

## How receive works

The CMT2300A is configured for direct mode, so its demodulated output appears
on `rx_pin`. An ISR timestamps edges into a ring buffer; `loop()` drains it,
filters short glitches, detects a frame between `start_pulse_min` and
`end_pulse`, and feeds the result to `remote_base` dumpers and `on_raw`
listeners.

Two details that matter:

- `digitalRead()` on a pin configured as an output reconfigures the pad and can
  break RX. Use the ISR path, not polling.
- The ISR ring buffer must be large enough for the whole burst plus the end
  pulse. A 132-element frame plus a 50 ms end pulse fits in `buffer_size: 2000`.

## How transmit works

`send_fifo_auto()`:

1. Re-initialise the radio from the 433.92 MHz register banks.
2. Measure the chip's bit period with 4-byte and 16-byte test packets.
3. Quantise the timings to that period (`encode_ook`).
4. Optionally negate every timing (polarity inversion).
5. For each repeat: clear FIFO, write payload, `GO_TX`, wait for TX to finish.
6. Restart the receiver.

The payload must fit the 32-byte FIFO. A 132-element OOK frame is ~26 bytes at
417 us/bit.

`send_internal()` — the `RemoteTransmitterBase` hook used by
`remote_transmitter` actions and by ESPHome's native `infrared` /
`radio_frequency` proxy entities — calls the same FIFO path with
`invert = true`. That means the HA entities work without a second transmit
implementation.

## Native Home Assistant entities

`sh4_rf` is a `RemoteTransmitterBase`, so ESPHome's `ir_rf_proxy` can drive it
directly:

```yaml
infrared:
  - platform: ir_rf_proxy
    name: "IR Blaster"
    remote_transmitter_id: ir_tx        # stock remote_transmitter on P7

radio_frequency:
  - platform: ir_rf_proxy
    name: "433 MHz RF"
    frequency: 433.92MHz
    remote_transmitter_id: rf           # this component
```

The `radio_frequency` platform validates `carrier_duty_percent` on the
transmitter; `sh4_rf` does not define that key, so the check passes. The RF
entity is transmit-only in HA (2026.5+); RF learning remains the custom
`on_raw` path.

## ESPHome compatibility

The component targets the ESPHome 2026.x `remote_base` trigger API. On older
versions the `validate_triggers` / `build_triggers` / `add_listener` calls differ;
either update ESPHome or adapt `__init__.py`.

## File map

| File | Purpose |
|------|---------|
| `__init__.py` | config schema, codegen, actions |
| `sh4_rf.h` | component class, public API |
| `sh4_rf.cpp` | SPI, RX ISR/pipeline, TX packet engine, diagnostics |
| `cmt2300a_params_433.h` | 433.92 MHz register banks |
| `automation.h` | receiver on/off and mode actions |
