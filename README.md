# odio-upmpdcli

upmpdcli packages for [odio](https://github.com/b0bbywan/odios), served from
[apt.odio.love](https://apt.odio.love). This repository mirrors the upstream
Debian builds by Jean-François Dockes, published on lesbonscomptes.com, so odio
installs and upgrades don't depend on a third-party APT repository.

Packages are not rebuilt: each release carries the upstream trixie builds for
amd64, arm64 and armhf, with unchanged version strings. Every release holds the
full set of packages, changed or not, since odio-apt-repo serves the latest
release only.

## Packages

- upmpdcli
- libupnpp17
- libnpupnp13
- upmpdcli-radios, upmpdcli-radio-browser, upmpdcli-radio-paradise,
  upmpdcli-mother-earth-radio, upmpdcli-qobuz, upmpdcli-tidal (all)

## Upstream sync

[`watch-upstream.yml`](.github/workflows/watch-upstream.yml) runs daily and
compares the upstream APT repositories with the latest release here:

| Arch  | Upstream repository |
|-------|---------------------|
| amd64, all | `https://www.lesbonscomptes.com/upmpdcli/downloads/debian`, suite `trixie` |
| arm64, armhf | `https://www.lesbonscomptes.com/upmpdcli/downloads/raspbian`, suite `trixie` (armhf built for ARMv6) |

When the packages differ, it pushes a tag and starts
[`build.yml`](.github/workflows/build.yml) on it, which downloads them,
publishes the release and triggers odio-apt-repo. Only `APT_REPO_TOKEN` is
needed: the watcher dispatches the build with `GITHUB_TOKEN`, since a tag it
pushes would not trigger the build by itself. Tags follow the upstream upmpdcli version
(`v1.10.1`); a change under the same upmpdcli version (library or plugin
update, Debian revision) gets `v1.10.1+1`, `v1.10.1+2`, and so on. Nothing is
tagged while the architectures disagree on a version, which happens while
upstream publishes its repositories one after the other.

`InRelease` is checked against the upstream key pinned in
[`keys/lesbonscomptes.gpg`](keys/lesbonscomptes.gpg) (fingerprint
`F8E3 3472 5692 2A8A E767 605B 7808 CE96 D38B 9201`, expires November 2028),
then each index and file against its SHA256.

The same script runs locally (needs curl, gpgv, dpkg, and gh for `plan`):

```bash
./scripts/sync-upstream.sh check                 # upstream versions
./scripts/sync-upstream.sh plan                  # next tag, if any
./scripts/sync-upstream.sh fetch --tag v1.10.1 dist
```

To release by hand, push the tag that `plan` prints, or run the watch workflow
from the Actions tab.

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
themselves differ from the originals. Later releases carry the original
upstream archives.

## Source and licenses

upmpdcli and libupnpp are GPL/LGPL, libnpupnp is BSD-like; see each package's
`/usr/share/doc/<package>/copyright`. Each release attaches the Debian source
packages the binaries were built from (`.dsc`, `.orig.tar.gz`,
`.debian.tar.xz`). When upstream no longer publishes a source package (a
plugin not rebuilt since an older upmpdcli), the signed upstream release
tarball is attached instead. Sources are also available at
[framagit.org/medoc92](https://framagit.org/medoc92).

The scripts and workflows of this repository are under the [MIT license](LICENSE);
it does not cover the mirrored packages.
