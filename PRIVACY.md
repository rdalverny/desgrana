# Privacy — Desgrana

Desgrana works strictly offline.

## Update check

The only network request Desgrana makes is a regular update check.

When enabled (the default), once a month,
it sends a single GET request to:

    https://romaindalverny.com/atelier/desgrana/version.json

It can be disabled in Preferences under "Check for updates automatically".


The request includes these query parameters:

| Parameter | Value                        | Example          |
| --------- | ---------------------------- | ---------------- |
| `os`      | Operating system             | `macos`          |
| `osv`     | OS or distro + major version | `15`, `debian12` |
| `arch`    | CPU architecture             | `arm64`          |
| `v`       | Application version          | `1.7`            |
| `l`       | System language code         | `en`             |

The purpose of these is to get an idea of the platforms usage,
for future support updates.

That is all, nothing else leaves your system.


On macOS it can also be disabled from the terminal:

    defaults write eu.elephathom.apps.desgrana UpdateCheck.enabled -bool false


## Contact

Questions: rwx@romaindalverny.com
