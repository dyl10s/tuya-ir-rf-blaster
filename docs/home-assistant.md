# Home Assistant usage

The component exposes ordinary ESPHome entities, so it works with the native
ESPHome integration (no custom integration needed).

## Entities

| Entity | Type | Purpose |
|--------|------|---------|
| `Send Builtin Frame` | button | replay a hardcoded, known-good frame |
| `RF Try Both` | button | replay inverted (working polarity) |
| `Learn Slot 1..6` | button | arm slot N; the next RF burst is saved |
| `Cancel Learn` | button | disarm learning |
| `Send Slot 1..6` | button | replay the saved frame |
| `Dump Slots` | button | log all slots to the ESPHome log |
| `Learning` | binary sensor | on while a slot is armed |
| `Learn Status` | text sensor | human-readable learn state |
| `Last RF Code` | text sensor | last raw capture as CSV |
| `Restart` | button | reboot the device |
| `IR Blaster` | `infrared` | native IR emitter (HA 2026.4+) |
| `433 MHz RF` | `radio_frequency` | native RF transmitter (HA 2026.5+) |

Object IDs are the snake_case versions, e.g. `button.ir_rf_blaster_send_slot_1`.

## Native HA IR/RF entities

The config also exposes Home Assistant's standard entity platforms:

```yaml
infrared:
  - platform: ir_rf_proxy
    name: "IR Blaster"
    remote_transmitter_id: ir_tx

radio_frequency:
  - platform: ir_rf_proxy
    name: "433 MHz RF"
    frequency: 433.92MHz
    remote_transmitter_id: rf
```

`ir_rf_proxy` is ESPHome's (experimental, 2026.9+) bridge between Home
Assistant and `remote_transmitter` / `remote_receiver`. The IR entity is backed
by the stock IR transmitter. The RF entity is backed by `sh4_rf` itself: it is a
`RemoteTransmitterBase`, and its `send_internal()` hook routes the proxy's raw
timings through the CMT2300A FIFO engine with inverted polarity.

What this gives you: the same architecture as the Bluetooth proxy. Any
device-specific integration that knows your appliance can send codes through
this hardware, and the entity appears as a normal HA entity instead of a pile of
buttons.

What it does **not** give you: a generic learn/replay UI. Home Assistant's
`infrared` and `radio_frequency` integrations are internal building blocks, not
user-facing services. You still need a consumer integration that knows the
device (LG Infrared, Samsung Infrared, Honeywell String Lights, Novy hood, ...)
or a community integration such as `ha-rf-remote` that turns captured codes into
buttons/switches. For arbitrary remotes, the six learn slots above remain the
simplest path.

RF **receive** is not part of HA's `radio_frequency` platform yet (it is
transmit-only as of 2026.5), so learning still uses `Learn Slot N` and the
ESPHome `on_raw` path.

## Learning a button

1. Press **Learn Slot N**. `Learning` turns on and `Learn Status` shows
   "Listening for slot N — press remote now".
2. Tap the remote button once. Do not hold it.
3. The burst is captured, sliced, quantised and stored. `Learning` turns off and
   `Learn Status` shows `Slot N saved (208 bits, 26 bytes)`.
4. Press **Send Slot N** to replay it.

What is stored is **not** the raw CSV. The frame is quantised to the
transmitter's bit period and packed as hex (208 bits = 52 hex characters). This
is deliberate: ESPHome string globals persist at most 254 bytes by default, and
a raw CSV is 600-1700 bytes, so it would come back empty after a reboot. Hex
fits comfortably and produces exactly the same payload the transmitter builds.

Slots use `restore_value: yes`, so they survive reboots. A firmware flash can
still wipe them; re-learn if `Dump Slots` reports `bytes=0`.

## Replaying

Each press sends **one** frame, matching one tap on the original remote. If the
target is a toggle (fan light, fan power), pressing the button once toggles it
once.

If a replay appears to do nothing:

- Make sure the slot is not empty (`Dump Slots`).
- Check the log: `FIFO auto: 26 bytes payload … (inverted)`.
- Confirm the frame was captured completely (compare two captures).

## Automations

Press a slot from an automation:

```yaml
action:
  - service: button.press
    target:
      entity_id: button.ir_rf_blaster_send_slot_1
```

Or wrap it in a script with a friendlier name:

```yaml
script:
  fan_light:
    alias: Fan light
    sequence:
      - service: button.press
        target:
          entity_id: button.ir_rf_blaster_send_slot_1
```

Expose slots to voice assistants / dashboards by giving the buttons friendly
names in Home Assistant (Settings → Entities → rename). The entity ID stays the
same, so automations keep working.

## Six slots

Six independent slots are enough for the usual set: light toggle, fan off, fan
low, fan medium, fan high, and one spare. Learn each button from the original
remote once.

## Multiple remotes

The same slots can hold frames from different remotes; the component does not
care what protocol a frame is, only that it is a complete OOK burst at
433.92 MHz. Fixed-code remotes replay perfectly. Rolling-code remotes
(Keeloq/HCS) will not: the receiver rejects a replayed counter.

## Range and reliability

TX uses the module's internal PA and PCB antenna. It reliably reaches a receiver
in the same room. If you need more range, the options are a better antenna or a
different transmitter; increasing the payload/repeats does not help and makes
toggle targets misbehave.

## Replacing the device

The config is portable: copy `components/sh4_rf/`, the YAML, and the learned
slots (re-learn, since slot storage lives in the device's flash, not in HA).
