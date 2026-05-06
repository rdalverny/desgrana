# Changelog

## [1.6.5] — 2026-05-02

- Move website to romaindalverny.com for now
- Project release on GitHub

## 1.6.x — 2026-04-24

### Features

- Quietly checks for updates (every 2 days at most)
- Open extracted session directly in Logic Pro or Reaper if installed
- DMG installer for macOS

### Fixes

- **Byte-exact extraction** — audio data is copied verbatim, no float32
  intermediate buffer, no format conversion or precision loss at any bit depth
  (16/24/32-bit int or float). Output files share the exact format of the
  source.

### Internal

- **Cross-platform architecture** — shared SPM target `DesgranaCore` holds all
  public types and utilities; `DesgranaCoreMac` (AudioToolbox) and
  `DesgranaCoreLinux` (dr_wav) contain only the platform-specific audio I/O
  backend. Zero `#if os()` in business logic.

## 1.5.x — 2026-04-21

### Features

- **Desktop output folder** — extraction goes to `~/Desktop/<session-name>/`
  by default, so you can work directly from an SD card without cluttering it.
  A "Choose…" button lets you pick another folder; the choice persists via
  `UserDefaults`.
- **Readable session name** — the name used for the output folder and
  filenames follows this priority: Wing snap `active_scene` → SE_LOG name if
  it is not a raw hex timestamp → folder name. Editable in the header before
  extraction.
- **Short filenames** — a "Short filenames" checkbox produces `KICK.wav`,
  `OH.wav` (channel name only) instead of `Session_ch01_KICK.wav`; falls back
  to `ch01.wav` if the channel has no name. Preference is remembered.
- **Stereo pair editing** — a link button per row in the Output section lets
  you unlink a pair or link two adjacent mono channels; Reset button if the
  configuration was changed manually.

### Fixes

- incorrect stereo pairs detection (`clink=true`)
- out-of-range stereo pairs are ignored when extracting
- channel names were read from `ae_data.ch.N.name` instead of following
  `ae_data.ch.N.in.conn → ae_data.io.in.[board][N].name`; explicit names
  configured on physical inputs are now used
- fix extraction summary track counts

## 1.4.0 — 2026-04-20

- reworked UI
- split result details
- output section detailed

## 1.3.0 - 2026-04-19

- **export markers to a MIDI file** (SMF type 0, SMPTE 25fps — imports
  natively in Logic Pro)

## 1.2.0 — 2026-04-18

- **split whole session takes into separate mono or stereo tracks** with
  embedded markers (cue chunk RIFF)
- export markers into a CSV file (Reaper & WaveLab)
- supports SE_LOG.bin session info
- supports Wing snapshot file:
  - auto-detected in session folder or manually added;
  - **extracts stereo pairs (`clink`) and channel names**
- drop a session folder on the app icon, or app window to pre-load it
- MIT License

---
