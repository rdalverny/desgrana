# Desgrana

> From session to mix.

> Extract channels from interleaved multitrack WAV files into individual
> mono/stereo ones.

**[Download & documentation → romaindalverny.com/atelier/desgrana](https://romaindalverny.com/atelier/desgrana/)**

Use case: you have a session recorded by a
[Behringer Wing](https://www.behringer.com/series.html?category=R-BEHRINGER-WINGSERIES)
console — several WAV files, plus `SE_LOG.bin` and `.snap`. With Desgrana, you
get each named channel in its own continuous WAV file, your markers exported
for your DAW, and a session ready to open.

## Features

- Your files come out exactly as recorded. No conversion, no precision loss,
  any bit depth.
- Runs fine on a laptop backstage. No freeze, no RAM issues, even on multi-GB
  sessions.
- Only the channels you actually recorded show up. No 32 empty tracks to clean
  up in your DAW.
- Your set markers land in Logic Pro, Reaper, and WaveLab; as cue chunks in
  the WAV, MIDI file, and CSV.
- Channel names and stereo pairs from your Wing snapshot (KICK, SNARE,
  JOE&hellip;) picked up automatically.
- Adjust stereo pairs before extraction: no need to re-export the snapshot
  from the console.
- Drop a session folder from Finder, or automate via CLI in your
  post-production workflow.
- Works entirely offline. Nothing uploaded, nothing tracked.

## Consoles supported

| Console        | Status              |
| -------------- | ------------------- |
| Behringer Wing | ✅ Tested           |
| Wing Rack      | ❓ feedback welcome |
| Wing Compact   | ❓                  |
| X-Live         | ❓                  |
| W-Live         | ❓                  |
| DN32-Live      | ❓                  |

## Privacy

Desgrana works entirely offline. It reads your local session files and writes
output to your local disk — nothing is uploaded or transmitted.

The only outbound request is an optional update check (at most once a month),
which fetches a public version file. No usage data, no identifiers, no
analytics.

## Usage

**GUI** — drop a session folder, with or without `.snap` file, click Extract.

**CLI**

```
desgrana <session-dir> [options]

Options:
  --output, -o <path>     Output directory (default: <session-dir>_extract/)
  --prefix, -p <string>   Prefix for output filenames
  --stereo, -s <pairs>    Stereo pairs, e.g. 1:2,3:4 (overrides --snap pairs)
  --snap   <file>         Wing snapshot (.snap) for stereo pairs and channel names
  --auto-stereo           Detect stereo pairs from channel names (ignores snap clink)
  --short-names           Use channel name only for filenames (e.g. KICK.wav, not prefix_ch01_KICK.wav)
  --dry-run               Show what would be extracted without writing any files
  --info,   -i            Show session info only, without extracting
  --help,   -h            Show this help

```

Output filenames follow the pattern `ChannelName.wav` (mono) or
`Name1-Name2.wav` (stereo). If no name is set, `ch01-ch02.wav` is used.
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

## Contributing & roadmap

See [CONTRIBUTING.md](CONTRIBUTING.md) for session format documentation, build
guidelines, and AI disclosure requirements.

Current major roadmap items:

- 1.8 — Linux port
- 1.9 — Windows port

## License

MIT — see [LICENSE](LICENSE).
