# odio-upmpdcli

upmpdcli packages for [odio](https://github.com/b0bbywan/odios), served from
[apt.odio.love](https://apt.odio.love). This repository mirrors the upstream
Debian builds by Jean-François Dockes, published on lesbonscomptes.com, so odio
installs and upgrades don't depend on a third-party APT repository.

Packages are not rebuilt: each release carries the upstream trixie builds for
amd64, arm64 and armhf, with unchanged version strings.

## Packages

- upmpdcli
- libupnpp17
- libnpupnp13
- upmpdcli-radios, upmpdcli-radio-browser, upmpdcli-radio-paradise,
  upmpdcli-mother-earth-radio, upmpdcli-qobuz, upmpdcli-tidal (all)

## v1.9.17: recovered packages

lesbonscomptes.com went down in October 2026, so the first release was
recovered with `dpkg-repack` from odio systems installed before the outage:

| Arch  | Source |
|-------|--------|
| amd64 | odios test baseline 2026.9.0b1 |
| arm64 | odios test baseline 2026.5.0b1 (from the 2026.5.0b1 SD image) |
| armhf | odios 2026.10.0b2 SD image (Raspberry Pi OS, ARMv6) |

`dpkg -V` reported no modified or missing file on any of them, conffiles
included, so the contents match the original packages. The `.deb` archives
themselves differ from the originals.

## Source and licenses

upmpdcli and libupnpp are GPL/LGPL, libnpupnp is BSD-like; see each package's
`/usr/share/doc/<package>/copyright`. The matching upstream sources are
attached to each release and available at
[framagit.org/medoc92](https://framagit.org/medoc92).
