# Omidi

A small macOS app that turns an Oura ring into a MIDI controller. The ring's accelerometer is read over Bluetooth, converted to **tilt** (pitch) and **roll** angles, and sent as MIDI Control Change (CC) messages on a virtual MIDI port named **Omidi**. A thumb **tap** on the ring steps through up to seven "modes", each with its own pair of CC numbers.

Omidi does not use the Oura cloud, account, or app. It talks directly to the ring using a bundled client (`oura`, from the open_oura project), so the ring must be a **spare, factory-reset ring** that Omidi pairs with itself (see [Pairing](#pairing)).

## How it works

```
Oura ring ──BLE──> oura accel --jsonl ──stdout──> RingStream ──> Controller ──> MidiOut ──> virtual MIDI port "Omidi"
                   (bundled subprocess)            (Ring.swift)   (Controller.swift)  (Midi.swift)
                                                                     │
                                                                     ├─ Motion.tilt: gravity → pitch / roll
                                                                     └─ TapDetector: jolts → taps → mode change
```

1. **Streaming.** `RingStream` launches the bundled `oura` binary as a subprocess (`oura accel --seconds 3600 --jsonl`). It emits one JSON line per accelerometer sample (~50 Hz): `{"t_ms":…,"x":…,"y":…,"z":…}` in raw counts (~1024 counts = 1 g). The app launches the process itself so macOS attributes the Bluetooth permission to Omidi. The stream is time-boxed to an hour; Omidi reconnects automatically when it ends.
2. **Orientation.** Each sample is low-pass filtered (`Controller.smooth = 0.2`, ~100 ms) to estimate the gravity vector, then `Motion.tilt` converts it to pitch and roll in degrees. The ring is assumed to be worn as a "finger gun" (index pointing, thumb up): gravity lies along +x, aiming up/down moves it along y, and banking right swings it toward −z.
3. **Scaling to CC.** Angles are taken relative to a zero pose (set by **Reset**), scaled across a symmetric range (the *span*, 10°–180°, so a span of 90° means −45°…+45°) and clamped to 0–127.
4. **Sending.** Values go out through a CoreMIDI virtual source (`MidiOut`) using MIDI 1.0 CC messages via UMP event lists. The port has a fixed unique ID so DAWs keep their mappings across relaunches.

### CC map

Mode *M* (1–7) sends:

| Message | CC number |
|---|---|
| Tilt | 10·M + 1 |
| Roll | 10·M + 2 |
| Tap (optional) | 10 |

So mode 1 is CC 11/12, mode 2 is CC 21/22, … mode 7 is CC 71/72. The tap CC (10) is the same in every mode and can be **Off**, **Momentary** (127 then 0 after 50 ms), or **Toggle** (alternates 127 / 0).

### "No jumps" behavior

Each axis (`Controller.Axis`) is *armed* after a mode change, channel change, reset, or unmute. An armed axis sends nothing until the hand has moved at least 8 CC steps from where it started, so switching modes never makes the new CC leap to wherever the hand happens to be. A 0.75-step hysteresis stops values flickering on a step boundary. MIDI is also held back briefly (200 ms) around a tap so the tap's own jolt doesn't move the CCs.

### Tap detection

`TapDetector` (in `Motion.swift`) works on the second difference of the raw samples (the "jolt"):

- A jolt above a floor (250 counts) starts a judgement; it is judged 6 samples (120 ms) later at its peak.
- **soft**: peak below the sensitivity threshold (1000 / 2000 / 3000 / 4000 / 5000 for Max…Min).
- **shaky**: peak less than 2× the background shake of the previous 500 ms (smooth hand motion, not a tap).
- **echo**: within 400 ms of a tap and under 35% of its size (the thumb lifting off).
- Otherwise it's a **tap**. After a tap there is a 0.5 s debounce.

Every judged jolt is appended as a JSON line to `~/Library/Logs/Omidi/taps.jsonl` (size, turn, sharpness, threshold, verdict) so sensitivity can be tuned from real data.

## The app

A fixed-size SwiftUI window with three tabs:

- **Play**: current mode (dots), live TILT and ROLL bars, **Reset** (Space) to make the current pose the middle, a **pause** button beside each of TILT and ROLL (each silences just that signal), and a status line with Reconnect / Pair buttons when the ring isn't streaming.
- **Settings**: tilt range, roll range, number of CC modes (1–7), MIDI channel (1–16), tap-as-MIDI (Off / Momentary / Toggle), tap sensitivity (with a live jolt meter), and ring pairing. Settings are stored in `UserDefaults`.
- **Info**: a short in-app explanation plus the CC table.

The menu bar is trimmed to the app menu. Quitting (or SIGTERM/SIGINT/SIGHUP) waits for the ring to switch its stream off; on launch, any `oura` process orphaned by a previous run is reaped so it can't hold the ring. The app also opts out of App Nap while streaming, so MIDI isn't delayed when the window is in the background.

## Pairing

Pairing installs Omidi's own auth key on a **factory-reset** ring, which makes the ring unusable with the Oura app and account until it is reset again and set up there. The Pairing panel walks through the reset on the charging dock (Gen3 / Ring 4 light sequence: blue → red → magenta → yellow), scans (~25 s) via `oura scan`, lets you choose the ring, and runs `oura pair`.

Pairing data lives in `~/Library/Application Support/Omidi/`:

- `ring.json`: the ring's Bluetooth address (as macOS identifies it on this Mac, so pairing is per Mac), key file name, display name
- `ring.key`: the auth key (mode 0600; the previous key is kept as `ring.key.old`)

A developer build can also import a ring already paired with the parent project's `pair.sh` (`../ring.json`, stamped into Info.plist as `RingConfig`).

## Project layout

| File | Role |
|---|---|
| [Sources/Omidi.swift](Sources/Omidi.swift) | App entry point, app delegate (signals, quit handling, menu trim, autostart streaming) |
| [Sources/Controller.swift](Sources/Controller.swift) | Core logic: settings, sample handling, CC scaling/arming, taps → modes, reconnects, tap log |
| [Sources/Motion.swift](Sources/Motion.swift) | Gravity → pitch/roll math; `TapDetector` |
| [Sources/Ring.swift](Sources/Ring.swift) | `RingConfig` (paired ring storage), `OuraTool` (running the bundled client), `RingStream` (subprocess + JSONL parsing) |
| [Sources/Pairing.swift](Sources/Pairing.swift) | Scan / pair flow state machine |
| [Sources/Midi.swift](Sources/Midi.swift) | CoreMIDI virtual source and CC sender |
| [Sources/Views.swift](Sources/Views.swift) | All SwiftUI views (black-and-white style) |
| [Info.plist](Info.plist) | Bundle metadata, Bluetooth usage string, macOS 14+ |
| [build.sh](build.sh) | Builds the `.app` |
| `Omidi.app/`, `dist/` | Build outputs (committed) |

## Building

Requires macOS 14+, the Xcode command line tools (`swiftc`), and the open_oura `oura` client built in the parent folder (by `../setup.sh`; override the path with `OURA_BIN`).

```sh
./build.sh            # builds Omidi.app
./build.sh --open     # builds it and launches it (quits a running copy first)
./build.sh --package  # builds dist/Omidi.app and dist/Omidi.zip to share
```

The build compiles `Sources/*.swift` with `swiftc`, copies `oura` into `Contents/MacOS`, and ad-hoc signs both. Note that `../setup.sh` and `../open_oura` are **not** in this repository, so the build can't run from a clean clone alone.

## Using it

1. Launch Omidi, pair a factory-reset ring, and allow Bluetooth when macOS asks.
2. In your DAW or synth, enable the MIDI input **Omidi**.
3. Use MIDI-learn on the CCs while moving your hand (tilt/roll), tapping to move between modes.

## Notes

- Some comments and messages refer to a "Start" button and to `/comps` design comps that don't exist in this repo; the app starts streaming automatically at launch.
- There are no tests.
