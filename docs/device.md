# The device

## What it is

A generic Tuya "IR + RF remote control" blaster, sold under many brands.
The unit used for this project is ASIN **B0D926FQRQ**, a small USB-powered puck
with an IR LED and a 433.92 MHz radio.

Despite the listing describing it as an RF *remote*, the hardware is a
transceiver: the radio can both receive and transmit. Tuya's stock firmware only
uses it for learning/replaying RF remotes, but the chip is capable of both.

## What's inside

| Part | Role |
|------|------|
| BK7231N (CBU) | Wi-Fi SoC, ARM Cortex-M4F + Wi-Fi, 2 MB flash |
| Tuya "SH4" RF module | 433.92 MHz front end |
| **CMT2300A** | the actual radio inside the SH4 module |
| IR LED + driver | IR blaster, on P7 |
| Status LED | P9 |

The SH4 module is not a bare radio: it is a small PCB containing the CMT2300A,
its matching network and antenna. The host talks to the CMT2300A over a
bit-banged 3-wire SPI bus.

### Identifying the radio

The CMT2300A exposes a product ID register at address `0x01`. Reading `0x66`
confirms the chip:

```
[sh4_rf] CMT2300A product_id=0x66 (expect 0x66)
```

If you get `0x00` or `0xFF`, the SPI wiring or chip-select polarity is wrong, or
the unit uses a different module.

## Pinout (verified on this board)

| Signal | BK7231N pin | Direction | Notes |
|--------|-------------|-----------|-------|
| SCLK | P14 | out | SPI clock, bit-banged |
| SDIO | P16 | in/out | SPI data, bidirectional |
| CSB | P6 | out | register chip select (active low) |
| FCSB | P26 | out | FIFO chip select (active low) |
| DOUT | P20 | in | demodulated RX data (direct mode) |
| IR TX | P7 | out | IR LED, `remote_transmitter` |
| Status LED | P9 | out | |

The CMT2300A's GPIO1/2/3 are wired to the host and can be configured as
DIN/DOUT/DCLK. **However, no usable DIN pin could be found on this board**:
driving every plausible host pin with every GPIO selection and both polarities
never produced RF. Transmit is therefore done with the chip's internal packet
engine, which does not need DIN at all.

## Antenna

The module uses a PCB antenna. RX sensitivity is good enough to hear a remote
from several rooms away; TX range with the internal PA is a few metres indoors,
which is fine for a ceiling fan in the same room.

## Variants

Tuya changes modules without changing the enclosure. Before assuming this
pinout, check:

1. The module marking (SH4 / CMT2300A).
2. `product_id == 0x66` over SPI.
3. That the RX pin produces clean pulses when a 433.92 MHz remote is pressed.

If the module is a different radio (e.g. a bare OOK receiver plus a separate
transmitter), this component will not apply.
