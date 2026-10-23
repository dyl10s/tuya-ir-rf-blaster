# RF reverse engineering: CMT2300A on the SH4 module

This is the part that took the longest. Everything below was verified on real
hardware; the register values are the ones that actually radiate a decodable
OOK signal.

## 1. The radio path

```
BK7231N  --bit-banged SPI-->  CMT2300A  --matching network-->  PCB antenna
             SCLK P14
             SDIO P16
             CSB  P6
             FCSB P26
             DOUT P20  <-- demodulated RX data (direct mode)
```

The CMT2300A has two ways to transmit OOK:

| Mode | Data source | Works here? |
|------|-------------|-------------|
| Direct mode | the DIN pin (host bit-bangs the PA) | ❌ no usable DIN pin found |
| Packet mode | the chip's TX FIFO + internal modulator | ✅ yes |

The stock Tuya firmware uses direct mode, which is why its register dump is a
trap: copy it and the chip will happily key the PA from a pin that nothing
drives. The packet engine is the way in.

## 2. The three bits that select the data source

The source selection is spread across three registers. **All three** must point
at the FIFO:

| Register | Address | Value | Field | Meaning |
|----------|---------|-------|-------|---------|
| `PKT1` | `0x38` | `0x02` | `DATA_MODE[1:0]` | packet mode |
| `TX1` | `0x55` | `0x51` | bit 2 `TX_DIN_SOURCE` | 0 = FIFO, 1 = GPIO/DIN |
| `FIFO_CTL` | `0x69` | `0x05` | bit 7 `TX_DIN_EN` | 0 = internal modulator |

`TX1 = 0x51` is `0x55 & ~0x04`. `FIFO_CTL = 0x05` is
`(old & ~0x80) | SPI_FIFO_RD_WR_SEL | FIFO_RX_TX_SEL`.

The failure mode is nasty: with the DIN source selected, the packet engine still
counts the payload length and the TX state lasts exactly the right amount of
time, so **airtime measurements look perfect** while the PA is keyed by a
floating pin. Do not use airtime alone as proof of transmission.

## 3. TX sequence that works

```text
GO_STBY                       MODE_CTL (0x60) = 0x02
PKT1   (0x38) = 0x02          packet mode
PKT2/3        = 0x00          no preamble
PKT5   (0x3C) = 0x00          no sync word
PKT14  (0x45) = 0x00          fixed length, length MSB
PKT15  (0x46) = len           payload length -- update for every frame
PKT26  (0x51) = 0x00          no TX prefix
PKT27/28      = 0x00          single packet, no inter-packet gap
PKT29  (0x54) = 0x10          FIFO threshold
TX1    (0x55) &= ~0x04        data from FIFO
FIFO_CTL (0x69) &= ~0x80
FIFO_CTL (0x69) |= 0x05       SPI write + TX FIFO
FIFO_CLR (0x6C) = 0x01
```

Then, for each repeat:

```text
FIFO_CLR = 0x01
delay 300 us
write payload bytes via FCSB
GO_TX                    MODE_CTL = 0x40
poll MODE_STA (0x61) until it leaves TX
GO_STBY
```

FIFO write timing matters: FCSB low for >= 2 us setup, >= 3 us hold, and
>= 6 us between bytes. Writes silently fail if you are too fast.

Other useful constants:

- `MODE_STA` (0x61): TX = 6, STBY = 2, TFS = 4.
- `FIFO_FLAG` (0x6E): `TX_FIFO_NMTY_FLG` = 0x02 (set after a successful write).
- TX FIFO is **32 bytes**; the encoder caps payloads at 32 bytes.
- `GO_SLEEP` = 0x10, `GO_STBY` = 0x02, `GO_TX` = 0x40.

## 4. Frame format

The remote used for development is a Hunter ceiling-fan remote (FCC ID
IN2TX52), 433.92 MHz OOK, **fixed code** (two presses seconds apart produce an
element-for-element identical capture).

Measured burst:

```
132 elements, 84.1 ms total
  element 0:  ~4845 us carrier  (sync)
  elements 1..131: 2 or 4 units, unit ~203 us
  alternating space/mark
```

Quantised to the transmitter's bit clock (~417 us), the burst becomes
**208 bits = 26 bytes**, which fits the 32-byte FIFO.

Important properties:

- **One tap = one burst.** Holding the button does not repeat. Replay one
  frame per press.
- **The whole burst is the frame.** An early capture was cut at 43 elements
  (~30 ms) and the receiver ignored it completely. Always verify the capture
  length against a second capture.
- The receiver has some data-slicer jitter (pairs like 437/369 us instead of
  406/406), but quantisation to whole bit periods preserves the bit stream.

## 5. Polarity: replay inverted

The CMT2300A's direct-mode DOUT on this module reports **carrier as low**. The
`on_raw` capture therefore stores "marks" that are actually gaps on air.

Replaying the captured timings verbatim (carrier on for a captured mark) does
nothing. Replaying with every timing negated (`invert = true`) works.

Practical rule: if a captured frame does not work in normal polarity, try
inverted before changing anything else. In our case inverted was the only one
that ever worked, and it works every time.

## 6. Bit rate: measure, do not assume

The chip's bit clock comes from its own configuration bank and is not exactly
the value in the datasheet. Measure it at runtime:

1. Transmit a 4-byte payload, time the TX state.
2. Transmit a 16-byte payload, time it.
3. `bit_us = (t16 - t4) / ((16 - 4) * 8)`.

On this board that gives **415-419 us/bit** (~2400 bps). There is also a fixed
~8 ms of per-packet overhead (startup/preamble); the subtraction removes it.

Do **not** try to change the rate through the `DR_M` registers (0x20-0x22).
Doing so collapsed TX to ~12 us on this hardware. Encode at the measured native
rate instead.

## 7. Encoding raw timings

`encode_ook()` converts a raw capture to a bit stream:

```
for each element:
    level = element > 0            // carrier on
    bits  = round(|element| / bit_us)
    emit `bits` copies of level, MSB first, packed into bytes
```

This is lossless enough for OOK replay as long as the bit clock matches the
transmitter's. It also means the same 26-byte payload is produced whether the
input is a raw microsecond array or the quantised hex string stored in a slot.

## 8. Recipe for a new remote

1. Configure the receiver (direct mode, `rx_pin`, 4 ms start pulse, 50 ms end
   pulse) and dump raw timings.
2. Tap the button twice; compare captures. They should be identical (fixed
   code) or the remote is rolling-code (raw replay will not work).
3. Make sure the capture is the **complete** burst: it should end with a long
   silence, not an arbitrary cut.
4. Quantise and encode at the measured bit rate.
5. Transmit **one** frame, **inverted** first.
6. If nothing happens, try normal polarity; then check the three source bits,
   then the frame length.
7. If it works, store the quantised bits (not the raw CSV) so it survives a
   reboot.

## 9. Gotchas checklist

| Symptom | Likely cause |
|---------|--------------|
| TX airtime correct, no reaction | `TX1` bit 2 still 1, or `FIFO_CTL` bit 7 still 1 |
| Works only sometimes | multiple repeats toggling the target |
| Works when sent twice, not once | frame truncated or wrong polarity |
| `FIFO_FLAG` never shows not-empty | SPI write mode/FCSB timing wrong |
| TX ends in ~12 us | `DR_M` rate registers changed |
| Learned slot empty after reboot | raw CSV too big for the string global; store hex |
| Chip not detected (`product_id != 0x66`) | SPI pins/CSB polarity |
