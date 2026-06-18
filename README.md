<p align="center">
  <img src="./web/icon_128x128.png" alt="Desgrana" width="120" />
</p>

<h1 align="center">Desgrana</h1>

<p align="center">
From session to mix.
<br>
Extract channels from interleaved multitrack WAV files into individual
mono/stereo named tracks.
</p>

<p align="center">
  Free &amp; open source ·  macOS & Linux
</p>

<p align="center">
  <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-1a1a1a" />
  <img alt="Platform: macOS" src="https://img.shields.io/badge/platform-macOS-1a1a1a" />
  <img alt="Platform: Linux" src="https://img.shields.io/badge/platform-linux-1a1a1a" />
  <a href="https://github.com/rdalverny/desgrana/actions"><img alt="CI" src="https://github.com/rdalverny/desgrana/actions/workflows/build.yml/badge.svg" /></a>
</p>

---


**[Download & documentation → romaindalverny.com/atelier/desgrana](https://romaindalverny.com/atelier/desgrana/)**

Use case: you have a multitrack session recorded by a
[Behringer Wing](https://www.behringer.com/series.html?category=R-BEHRINGER-WINGSERIES)
or X32 using the W-Live or X-Live recorder — several WAV files, plus
`SE_LOG.bin` and optionally a `.snap`. With Desgrana, you get each named
channel in its own continuous WAV file, your markers exported for your DAW,
and a session ready to open.

## Features

- Keeps your audio the same, obviously. No conversion, only demux.
- Exports only the noisy channels. No empty track to manually dismiss.
- Exports session markers in exported WAV, MIDI and CSV, to reuse in DAWs.
- Picks up channel names and stereo pairs from your console snapshot.
- Works entirely offline. Nothing uploaded, nothing tracked.
- Opens all extracted tracks in Logic Pro, Reaper, or Ardour on macOS.
  See [CONTRIBUTING](CONTRIBUTING.md) for adding another one.

## Privacy

Desgrana works entirely offline. It reads your local session files and writes
output to your local disk — nothing is uploaded or transmitted.

The only outbound request is an optional update check (at most once a month).
It sends OS name, version, CPU architecture, app version, and system language.
Nothing else. See [PRIVACY.md](PRIVACY.md) for full details and how to disable
it.

## Usage

**GUI** — drop a session folder in the app, with or without a `.snap` file,
click Extract.

**CLI**

```
desgrana <session-dir> [options]

Options:
  --output, -o <path>     Output directory (default: <session-dir>_extract/)
  --prefix, -p <string>   Prefix for output filenames
  --stereo, -s <pairs>    Stereo pairs, e.g. 1:2,3:4 (overrides snap-derived pairs)
  --snap   <file>         Console snapshot (.snap for Wing, .scn for X32) for channel names and USB stereo pairs
  --short-names           Use channel name only for filenames (e.g. KICK.wav, not prefix_ch01_KICK.wav)
  --dry-run               Show what would be extracted without writing any files
  --info, -i              Show session info only, without extracting
  --help, -h              Show this help

```

Output filenames follow the pattern `ChannelName.wav` (mono) or
`Name1-Name2.wav` (stereo). If no name is set, `ch01-ch02.wav` is used.
Channel names come from the console snapshot (`.snap` for Wing, `.scn` for
X32).

## Build

```bash
make cli        # → var/shipit/desgrana (CLI binary, macOS)
make cli-linux  # → desgrana/.build/release/desgrana (build and run on Linux)
make bundle     # → var/build/Desgrana.app

make test       # build CLI + run byte-exact integration test
make lint       # SwiftLint (brew install swiftlint)
make format     # swift-format (brew install swift-format)
```

## Contributing & roadmap

See [CONTRIBUTING.md](CONTRIBUTING.md) for session format documentation, build
guidelines, roadmap, and AI disclosure requirements.

## License

MIT — see [LICENSE](LICENSE).
