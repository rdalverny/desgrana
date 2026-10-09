# Privacy — Desgrana

Desgrana works strictly offline.

## Update check

The only network request Desgrana makes is an optional update check.

When enabled, it sends a single GET request, once a week, month or six months
(monthly by default), to:

    https://romaindalverny.com/desgrana/version.json

The request includes these query parameters:

| Parameter | Value                        | Example                 |
| --------- | ---------------------------- | ----------------------- |
| `os`      | Operating system             | `macos`, `windows`      |
| `osv`     | OS or distro + major version | `15`, `11`, `debian12`  |
| `arch`    | CPU architecture             | `arm64`                 |
| `v`       | Application version          | `1.7`                   |
| `l`       | System language code         | `en`                    |

The purpose of these is to get an idea of the platforms usage, for future
support updates.

That is all, nothing else leaves your system.

## Turning it on or off

In Preferences, "Check for updates automatically":

| Platform | Menu                  | Default |
| -------- | --------------------- | ------- |
| macOS    | Desgrana > Settings…  | on      |
| Linux    | Edit > Preferences…   | on      |
| Windows  | Tools > Options…      | off     |

On Windows, the installer also shows this policy and offers the choice
("Check for updates" option).

## Contact

Questions: rwx@romaindalverny.com
