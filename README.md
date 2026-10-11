<p align="center">
  <img src="./web/icon_128x128.png" alt="Desgrana" width="120" />
</p>

<h1 align="center">Desgrana</h1>

<p align="center">
From session to mix.<br>
Extract channels from interleaved multitrack WAV files<br>
into individual mono/stereo named tracks.<br>
Works with Behringer Wing, X32 consoles.
</p>

<p align="center">
Free &amp; open source ·
macOS, Linux &amp; Windows
</p>

<p align="center">
  <a href="https://github.com/rdalverny/desgrana/actions"><img alt="CI" src="https://github.com/rdalverny/desgrana/actions/workflows/build.yml/badge.svg" /></a>
</p>

---


**[Download & documentation → romaindalverny.com/desgrana](https://romaindalverny.com/desgrana/)**

Use case: you have a multitrack session recorded by a
[Behringer Wing](https://www.behringer.com/)
or X32 using the W-Live or X-Live recorder — several WAV files, plus
`SE_LOG.bin` and optionally a `.snap`. With Desgrana, you get each named
channel in its own continuous WAV file, your markers exported for your DAW,
and a session ready to open.

## Features

- Keeps your audio the same, obviously. No conversion, only demux.
- Picks up channel names and stereo pairs from your console snapshot.
- Automatically dismiss empty tracks.
- Keeps source metadata into exported tracks.
- Exports session markers in exported WAV, MIDI and CSV, to reuse in DAWs.
- Opens extracted tracks ready to work in your DAW.
- Works offline.
- Optional updates online check (defaults to on, see PRIVACY.md)


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

## Contributing & Roadmap

See [CONTRIBUTING.md](CONTRIBUTING.md) for session format documentation,
build guidelines and roadmap.

## License

MIT — see [LICENSE](LICENSE).
