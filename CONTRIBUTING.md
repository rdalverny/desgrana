# Contributing

## Before you start

Open an issue first to discuss the change. This avoids wasted effort if the
direction doesn't fit the project.

## Workflow

1. Open an issue, discuss the change.
1. Fork, branch, implement.
1. `make test` — must pass.
1. `make lint` — must pass.
1. Open a pull request referencing the issue.
1. After a positive review, the PR gets merge.

## Session format

Each recording session is a folder (hex timestamp) containing:

- `SE_LOG.BIN` — 2048-byte binary metadata (little-endian)
- `MyShow.snap` — Wing snapshot (optional, JSON)
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

### Gotchas

- **`clink=true` on all channels by default** — the Wing ships with every
  channel stereo-linked (factory state). If the user hasn't configured their
  stereo pairs before exporting the snap, Desgrana will see everything as
  stereo. Solution: the user should configure stereo pairs on the console
  before exporting, or drop the snap to get all-mono output.

- **`clink` is written on both channels of a pair** — the parser must skip
  channels already claimed as the "right" side of a pair (`claimedRight` set),
  to avoid counting them twice.

- **Snap has 40 channels, session may have fewer** — the Wing AE snap always
  contains 40 channel entries even if fewer were recorded. Pairs referencing
  out-of-range channels are silently ignored (warning logged, no fatal error).

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
