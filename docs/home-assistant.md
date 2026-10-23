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

Object IDs are the snake_case versions, e.g. `button.ir_rf_blaster_send_slot_1`.

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
