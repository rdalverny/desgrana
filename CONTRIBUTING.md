# Contributing

## Build prerequisites

### macOS

- Xcode 15 or later (Swift 5.9+)
- SwiftLint: `brew install swiftlint`
- swift-format: `brew install swift-format`

```bash
make cli     # CLI binary
make bundle  # Desgrana.app
make test    # build + integration tests
```

### Linux

```bash
# 1. System dependencies
# Debian/Ubuntu:
sudo apt install binutils libcurl4 libxml2 libz3-dev
# Fedora:
sudo dnf install binutils libcurl libxml2 z3-devel

# 2. Install Swift for your distro: https://www.swift.org/install/linux/

# 3. Build dependencies (Qt + tools)
# Debian/Ubuntu:
sudo apt install cmake ninja-build qt6-base-dev libgl1-mesa-dev libxkbcommon-dev git
# Fedora:
sudo dnf install cmake ninja-build qt6-qtbase-devel mesa-libGL-devel libxkbcommon-devel git

make build-linux          # CLI + Qt GUI binary
make package-debian       # .deb amd64 → dist/
make package-debian-arm64 # .deb arm64 → dist/
make test-image           # build the Docker tester image (once)
make test-debian          # install the .deb and run the CLI test suite
```

You may need to adjust `SWIFT_*` variables in the Makefile to match your Swift
installation path.

## Before you start

Open an issue first to discuss the change. This avoids wasted effort if the
direction doesn't fit the project.

## Workflow

1. Open an issue, discuss the change.
1. Fork, branch from `main`, implement.
1. `make test` — must pass.
1. `make lint` — must pass.
1. Open a pull request referencing the issue.
1. After a positive review, the PR gets merged.

## Session format

Each recording session is a folder (hex timestamp) containing:

- `SE_LOG.BIN` — 2048-byte binary metadata (little-endian); optional, but required for marker export
- `<SceneName>.snap` — Wing snapshot (optional, JSON)
- `00000001.WAV`, `00000002.WAV`, … — interleaved multichannel WAV files

The Wing creates a new WAV file each time the previous one hits 4 GB (FAT32
limit). Desgrana processes all take files in order and writes them as a single
continuous output per channel.

### SE_LOG.BIN

Code based on the data structure reverse engineered by Patrick-Gilles Maillot
in [X32-Behringer project](https://github.com/pmaillot/X32-Behringer), GPL.

Key offsets (little-endian):

| Offset | Size     | Description                           |
| ------ | -------- | ------------------------------------- |
| 0      | uint32   | Session timestamp (hex yymmhhmm)      |
| 4      | uint32   | Number of channels                    |
| 8      | uint32   | Sample rate                           |
| 16     | uint32   | Number of takes                       |
| 20     | uint32   | Number of markers                     |
| 24     | uint32   | Total length in samples               |
| 28     | 256×u32  | Take sizes                            |
| 1052   | 100×u32  | Marker positions (in samples)         |
| 1553   | 16 bytes | Session name (ASCII, null-terminated) |

### Wing snapshot (`.snap`)

Wing snapshots are JSON files exported from the console.

Channel names are stored in the physical input entries, not in the channel
strip:

| Path                              | Type   | Description                                      |
| --------------------------------- | ------ | ------------------------------------------------ |
| `ae_data.io.in.<card><N>.name`    | string | Physical input name (KICK, VOX, …)               |
| `ae_data.ch.<N>.in.conn.{grp,in}` | —      | Routing: which physical input feeds this channel |
| `ae_data.ch.<N>.clink`            | bool   | Stereo link with channel N+1                     |

Note: `ae_data.ch.<N>.name` exists in the JSON but is empty by default on the
Wing. Channel names must be retrieved via the physical input routing path
above.

### X32/M32 snapshot (`.scn`)

X32 and M32 scene files are plain-text OSC key/value, one parameter per line.
Parsed by `Sources/Core/X32Scene.swift`. Full format spec and implementation
notes are in [`X32.md`](X32.md).

Key fields extracted:

| Path                        | Description                              |
| --------------------------- | ---------------------------------------- |
| `/ch/XX/config/name "Name"` | Channel name (XX = 01–32, zero-padded)   |
| `/config/chlink1-2 ON`      | Stereo link for the 1–2 pair (odd+even)  |
| `/show/name "Scene"`        | Scene name (optional; falls back to filename) |

Both `chlink1-2` and `chlink01-02` key formats are accepted (firmware varies).
Booleans are `ON`/`OFF` or `1`/`0`. The parser returns a `SnapInfo`, the same
type as the Wing snap parser — no special handling needed downstream.

## Roadmap

The roadmap is indicative, not a commitment. Priorities may shift.

Current focus:
- X-Live / W-Live validation with real session samples
- X32/M32 support testing (parser implemented, needs real-world `.scn` files)
- CLI manpage

Under consideration (no timeline):
- DAW export: "Open in DAW" button on Linux (Core already generates `.rpp`/`.ardour`)
- AAF export for Pro Tools, Nuendo, Cubase (requires libaaf integration)
- Per-take extraction (value to confirm with users before implementing)
- Localization

Not planned at this stage:
- Windows port

## AI disclosure

This project is built with AI assistance. If your contribution includes
AI-generated code, add these trailers to each relevant commit:

```
Co-Authored-By: <AI Name Version> <noreply@provider.com>
AI-Assisted: generated|partial|suggestion
```

- `generated` — AI wrote the bulk of it; you reviewed and validated.
- `partial` — collaborative; you directed, AI implemented portions.
- `suggestion` — AI proposed an approach or snippet; you wrote the code.

Omit for minor assistance (lookups, explanations, rephrasing).

Example for Claude:

```
Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
AI-Assisted: partial
```

## License

By contributing, you agree your changes are released under the project's
[MIT license](LICENSE).
