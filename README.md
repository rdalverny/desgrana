# Desgrana

> Extract channels from interleaved multitrack WAV files
> into individual mono/stereo ones.

Use case:
- you have several WAV files from a session recorded
  by a [Behringer Wing](https://www.behringer.com/series.html?category=R-BEHRINGER-WINGSERIES) console, plus the SE_LOG.bin and .snap files;
  they don't open easily directly in your DAW (yet).
- with desgrana, you:
  - get each named part in its own continuous WAV file,
    a MIDI file with the session markers (if you used them),
    all extracted in a new folder,
  - plus a DAW session loaded and ready to use.

[Get the latest release](https://github.com/rdalverny/desgrana/releases)


## Features

- Byte-exact extraction — audio data is copied verbatim.
  No conversion, no resampling, no dithering.
- Streams audio in blocks, handles large files with constant memory
  (fast, doesn't freeze your computer)
- Reads session metadata from `SE_LOG.BIN` if present
  (channel count, sample rate, duration, markers)
- Reads Wing snapshot (`.snap`) if present
  for stereo pairs and channel names
- Skips silent (all-zero) channels automatically
- Exports markers as `cue ` chunks in output WAVs, plus MIDI, CSV
- Detects and reports missing takes
- (macOS) GUI (drag & drop, accepts `.snap` drop) and CLI
- (macOS) Released app and CLI are signed and notarized


## Consoles supported

- [Behringer Wing](https://www.behringer.com/series.html?category=R-BEHRINGER-WINGSERIES): yes
- X-Live & W-Live: to be tested


## Usage

**GUI** — drop a session folder, with or without `.snap` file, click Extract.

**CLI**
```
desgrana <session-dir> [options]

Options:
  --output, -o <path>     Output directory (default: <session-dir>_extract/)
  --prefix, -p <string>   Prefix for output filenames
  --snap       <file>     Wing snapshot (.snap) — stereo pairs + channel names
                          (auto-detected if present in session dir)
  --stereo, -s <pairs>    Stereo pairs, e.g. 1:2,3:4 (overrides --snap pairs)
  --info,   -i            Show session info only, without extracting
  --help,   -h            Show this help
```

Output filenames follow the pattern `ChannelName.wav` (mono)
or `Name1-Name2.wav` (stereo). If no name is set, `ch01-ch02.wav` is used.
Channel names come from the `.snap` file.


## Build

```bash
make cli        # → var/shipit/desgrana (CLI binary, macOS)
make cli-linux  # → desgrana/.build/release/desgrana (run on Linux)
make bundle     # → var/build/Desgrana.app

make test       # build CLI + run byte-exact integration test
make lint       # SwiftLint (brew install swiftlint)
make format     # swift-format (brew install swift-format)
```

## Session format

Each recording session is a folder (hex timestamp) containing:
- `SE_LOG.BIN` — 2048-byte binary metadata (little-endian)
- `MyShow.snap` — Wing snapshot (optional, JSON)
- `00000001.WAV`, `00000002.WAV`, … — interleaved multichannel WAV files


### SE_LOG.BIN

Code based on the data structure reverse engineered by Patrick-Gilles Maillot
in [X32-Behringer project](https://github.com/pmaillot/X32-Behringer), GPL.


### Wing snapshot (`.snap`)

Wing snapshots are JSON files exported from the console.
Relevant fields used by Desgrana:

| Path                   | Type   | Description    |
|------------------------|--------|----------------|
| `ae_data.ch.<N>.name`  | string | Channel name   |
| `ae_data.ch.<N>.clink` | bool   | Stereo link with channel N+1 |


## License

MIT — see [LICENSE](LICENSE).


## Contributing, maintenance & roadmap

Developed with AI assistance ([Claude Code](https://claude.ai/code)).

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines,
including AI disclosure requirements for contributed code.

Current major roadmap items include:
- 1.7, a simplified UI (see branch `ui`)
- 1.8, a Linux release (likewise `linux`)
- 1.9, a Windows release

