#!/usr/bin/env bash
#
# Mirror the upstream upmpdcli trixie builds published by Jean-François Dockes
# on lesbonscomptes.com.
#
# Commands:
#   check                  print the upstream version of every mirrored package
#   plan                   print the tag to release next, or nothing if this
#                          repository is up to date (the reasoning goes to
#                          stderr, and to $GITHUB_STEP_SUMMARY when set)
#   fetch --tag TAG DIR    download the .debs and their sources into DIR
#
# Nothing is trusted on the way: InRelease is checked against the pinned
# keyring in keys/, the Packages/Sources indexes against InRelease, and every
# downloaded file against its index (or its detached signature for tarballs).

set -euo pipefail

UPSTREAM="${UPSTREAM:-https://www.lesbonscomptes.com/upmpdcli/downloads}"
SUITE=trixie
KEY_FPR=F8E3347256922A8AE767605B7808CE96D38B9201

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEYRING="${ROOT}/keys/lesbonscomptes.gpg"

# arch:repository. arm64 and armhf come from the raspbian repository, whose
# armhf is built for ARMv6 (Raspberry Pi Zero/1); the armhf index of the debian
# repository is no longer updated upstream.
ARCH_REPOS=(amd64:debian arm64:raspbian armhf:raspbian)
# arch:all packages are built separately in each repository (the files differ),
# so they are taken from the first entry of ARCH_REPOS only.
ARCH_PKGS=(upmpdcli libupnpp17 libnpupnp13)
ALL_PKGS=(
  upmpdcli-radios
  upmpdcli-radio-browser
  upmpdcli-radio-paradise
  upmpdcli-mother-earth-radio
  upmpdcli-qobuz
  upmpdcli-tidal
)

die() { echo "error: $*" >&2; exit 1; }
log() { echo "$*" >&2; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
export GNUPGHOME="${WORK}/gnupg"
mkdir -m 700 "${GNUPGHOME}"

download() {
  curl -fsSL --retry 3 --max-time 300 -o "$2" "$1" || die "download failed: $1"
}

verify_sha256() {
  local file="$1" expected="$2" actual
  actual="$(sha256sum "${file}" | cut -d' ' -f1)"
  [ "${actual}" = "${expected}" ] || die "SHA256 mismatch for ${file##*/}: got ${actual}, want ${expected}"
}

check_keyring() {
  local fpr
  fpr="$(gpg --show-keys --with-colons "${KEYRING}" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')"
  [ "${fpr}" = "${KEY_FPR}" ] || die "${KEYRING} has fingerprint '${fpr}', expected ${KEY_FPR}"
}

# Download and verify InRelease of a repository; leaves the signed payload in
# ${WORK}/<repo>/Release.
load_release() {
  local repo="$1" dir="${WORK}/$1"
  [ -f "${dir}/Release" ] && return
  mkdir -p "${dir}"
  download "${UPSTREAM}/${repo}/dists/${SUITE}/InRelease" "${dir}/InRelease"
  gpgv --quiet --keyring "${KEYRING}" --output "${dir}/Release" "${dir}/InRelease" 2>/dev/null \
    || die "bad signature on ${repo}/dists/${SUITE}/InRelease"
}

# Print the local path of an index (e.g. main/source/Sources) of a repository,
# downloaded as .gz and checked against Release. The server mislabels the
# uncompressed indexes, so the .gz is always used.
index_file() {
  local repo="$1" path="$2" out="${WORK}/$1/$2" sha
  if [ ! -f "${out}" ]; then
    load_release "${repo}"
    sha="$(awk -v p="${path}.gz" '/^SHA256:/ { s = 1; next } /^[^ ]/ { s = 0 } s && $3 == p { print $1 }' "${WORK}/${repo}/Release")"
    [ -n "${sha}" ] || die "${repo}: ${path}.gz is not listed in Release"
    mkdir -p "$(dirname "${out}")"
    download "${UPSTREAM}/${repo}/dists/${SUITE}/${path}.gz" "${out}.gz"
    verify_sha256 "${out}.gz" "${sha}"
    gzip -dc "${out}.gz" > "${out}"
  fi
  echo "${out}"
}

# Print "package version arch filename sha256 source source_version" for each
# stanza of a Packages index whose package is in $2 (space separated) and whose
# architecture is $3.
parse_packages() {
  awk -v wanted="$2" -v want_arch="$3" '
    BEGIN {
      RS = ""; FS = "\n"
      n = split(wanted, w, " "); for (i = 1; i <= n; i++) want[w[i]] = 1
    }
    {
      pkg = ver = arch = fn = sha = src = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^Package: /) pkg = substr($i, 10)
        else if ($i ~ /^Version: /) ver = substr($i, 10)
        else if ($i ~ /^Architecture: /) arch = substr($i, 15)
        else if ($i ~ /^Filename: /) fn = substr($i, 11)
        else if ($i ~ /^SHA256: /) sha = substr($i, 9)
        else if ($i ~ /^Source: /) src = substr($i, 9)
      }
      if (!(pkg in want) || arch != want_arch) next
      sver = ver
      if (src == "") src = pkg
      else if (match(src, / \(.*\)$/)) { sver = substr(src, RSTART + 2, RLENGTH - 3); src = substr(src, 1, RSTART - 1) }
      print pkg "\t" ver "\t" arch "\t" fn "\t" sha "\t" src "\t" sver
    }' "$1"
}

# Keep the highest version of each package from parse_packages output on stdin.
highest() {
  local -A best=() line=()
  local pkg ver rest
  while IFS=$'\t' read -r pkg ver rest; do
    if [ -z "${best[${pkg}]:-}" ] || dpkg --compare-versions "${ver}" gt "${best[${pkg}]}"; then
      best[${pkg}]="${ver}"
      line[${pkg}]="${pkg}"$'\t'"${ver}"$'\t'"${rest}"
    fi
  done
  for pkg in "${!line[@]}"; do echo "${line[${pkg}]}"; done
}

# Build ${WORK}/manifest.tsv: "package version arch repo filename sha256 source
# source_version", one line per .deb to mirror. Sets MIDWAY when the
# architectures disagree on a version: upstream publishes the debian and
# raspbian repositories at different times, so that is a state to wait out.
MANIFEST="${WORK}/manifest.tsv"
MIDWAY=""
resolve() {
  [ -f "${MANIFEST}" ] && return
  check_keyring
  local entry arch repo packages found pkg missing=() first_arch="" first_repo=""
  : > "${MANIFEST}"
  for entry in "${ARCH_REPOS[@]}"; do
    IFS=: read -r arch repo <<< "${entry}"
    [ -n "${first_arch}" ] || { first_arch="${arch}"; first_repo="${repo}"; }
    packages="$(index_file "${repo}" "main/binary-${arch}/Packages")"
    found="$(parse_packages "${packages}" "${ARCH_PKGS[*]}" "${arch}" | highest)"
    for pkg in "${ARCH_PKGS[@]}"; do
      grep -q "^${pkg}"$'\t' <<< "${found}" || missing+=("${pkg} (${arch})")
    done
    [ -z "${found}" ] || awk -v r="${repo}" 'BEGIN { FS = OFS = "\t" } { print $1, $2, $3, r, $4, $5, $6, $7 }' <<< "${found}" >> "${MANIFEST}"
  done
  packages="$(index_file "${first_repo}" "main/binary-${first_arch}/Packages")"
  found="$(parse_packages "${packages}" "${ALL_PKGS[*]}" all | highest)"
  for pkg in "${ALL_PKGS[@]}"; do
    grep -q "^${pkg}"$'\t' <<< "${found}" || missing+=("${pkg} (all)")
  done
  [ -z "${found}" ] || awk -v r="${first_repo}" 'BEGIN { FS = OFS = "\t" } { print $1, $2, $3, r, $4, $5, $6, $7 }' <<< "${found}" >> "${MANIFEST}"
  [ "${#missing[@]}" -eq 0 ] || die "not found upstream: ${missing[*]}"

  local versions
  for pkg in "${ARCH_PKGS[@]}"; do
    versions="$(awk -v p="${pkg}" -F'\t' '$1 == p { print $3 "=" $2 }' "${MANIFEST}" | sort)"
    if [ "$(cut -d= -f2 <<< "${versions}" | sort -u | wc -l)" -ne 1 ]; then
      MIDWAY+="${MIDWAY:+; }${pkg} $(paste -sd' ' <<< "${versions}")"
    fi
  done
  sort -o "${MANIFEST}" "${MANIFEST}"
}

# 1:1.10.1-1~ppa1~trixie -> 1.10.1
upstream_version() { sed -E 's/^[0-9]+://; s/-[^-]*$//' <<< "$1"; }

manifest_version() { awk -v p="$1" -F'\t' '$1 == p { print $2; exit }' "${MANIFEST}"; }

# GitHub replaces '~' with '.' in release asset names.
expected_assets() { awk -F'\t' '{ n = split($5, a, "/"); f = a[n]; gsub(/~/, ".", f); print f }' "${MANIFEST}" | sort; }

# Same mapping as tag_to_debver in odio-apt-repo.
tag_to_debver() { sed -E 's/^v//; s/-/~/' <<< "$1"; }

cmd_check() {
  resolve
  awk -F'\t' '{ printf "%-30s %-6s %-28s %s\n", $1, $3, $2, $4 }' "${MANIFEST}"
  [ -z "${MIDWAY}" ] || log "upstream is midway through a publication: ${MIDWAY}"
}

# Decide what to release. Sets TAG (empty when there is nothing to release),
# VERDICT (one line) and CHANGES (asset diff against the latest release).
# Tags are vX.Y.Z after the upstream upmpdcli version, and vX.Y.Z+N when only
# other packages (libraries, plugins) changed under the same upmpdcli version.
TAG="" VERDICT="" CHANGES=""
decide() {
  local base tags newest="" t released n
  if [ -n "${MIDWAY}" ]; then
    VERDICT="upstream is midway through a publication (${MIDWAY}), nothing to tag"
    return
  fi
  base="v$(upstream_version "$(manifest_version upmpdcli)")"
  tags="$(git -C "${ROOT}" tag -l 'v*')"
  for t in ${tags}; do
    if [ -z "${newest}" ] || dpkg --compare-versions "$(tag_to_debver "${t}")" gt "$(tag_to_debver "${newest}")"; then
      newest="${t}"
    fi
  done

  if [ -n "${newest}" ]; then
    if ! released="$(gh release view "${newest}" --repo "${GH_REPO:-b0bbywan/odio-upmpdcli}" \
          --json assets --jq '.assets[].name | select(endswith(".deb"))' 2>/dev/null)"; then
      VERDICT="tag ${newest} has no release yet (build pending or failed), nothing to tag"
      return
    fi
    if [ "$(sort <<< "${released}")" = "$(expected_assets)" ]; then
      VERDICT="${newest} matches upstream, nothing to tag"
      return
    fi
    CHANGES="$(diff <(sort <<< "${released}") <(expected_assets) | grep '^[<>]' || true)"
    if dpkg --compare-versions "$(tag_to_debver "${base}")" lt "$(tag_to_debver "${newest%+*}")"; then
      die "upstream upmpdcli ${base} is older than ${newest}"
    fi
  fi

  TAG="${base}"
  if grep -qxF "${base}" <<< "${tags}"; then
    n=1
    while grep -qxF "${base}+${n}" <<< "${tags}"; do n=$((n + 1)); done
    TAG="${base}+${n}"
  fi
  VERDICT="upstream differs from ${newest:-the (absent) releases}, next tag: ${TAG}"
}

cmd_plan() {
  resolve
  decide
  cmd_check >&2
  log "${VERDICT}"
  [ -z "${CHANGES}" ] || log "${CHANGES}"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### ${VERDICT^}"
      echo
      package_table
      if [ -n "${CHANGES}" ]; then
        echo
        echo '```diff'
        sed 's/^</-/; s/^>/+/' <<< "${CHANGES}"
        echo '```'
      fi
    } >> "${GITHUB_STEP_SUMMARY}"
  fi
  [ -z "${TAG}" ] || echo "${TAG}"
}

# Print "directory sha256 filename" for each file of a source package found in
# the Sources index of any repository, from the first repository carrying it.
source_files() {
  local src="$1" sver="$2" entry repo sources out
  for entry in "${ARCH_REPOS[@]}"; do
    repo="${entry#*:}"
    sources="$(index_file "${repo}" main/source/Sources)"
    out="$(awk -v p="${src}" -v v="${sver}" '
      BEGIN { RS = ""; FS = "\n" }
      {
        pkg = ver = dir = ""; insha = 0; nf = 0
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^ / && insha) { split(substr($i, 2), a, " "); files[++nf] = a[1] "\t" a[3]; continue }
          insha = 0
          if ($i ~ /^Package: /) pkg = substr($i, 10)
          else if ($i ~ /^Version: /) ver = substr($i, 10)
          else if ($i ~ /^Directory: /) dir = substr($i, 12)
          else if ($i ~ /^Checksums-Sha256:/) insha = 1
        }
        if (pkg == p && ver == v) { for (j = 1; j <= nf; j++) print dir "\t" files[j]; exit }
      }' "${sources}")"
    if [ -n "${out}" ]; then
      # shellcheck disable=SC2001 # prefixes every line
      sed "s|^|${repo}/|" <<< "${out}"
      return
    fi
  done
}

cmd_fetch() {
  local tag="" out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --tag) tag="${2:-}"; shift 2 ;;
      -*) die "unknown option $1" ;;
      *) out="$1"; shift ;;
    esac
  done
  [ -n "${tag}" ] && [ -n "${out}" ] || die "usage: $0 fetch --tag TAG DIR"
  [ ! -e "${out}" ] || [ -z "$(ls -A "${out}")" ] || die "${out} is not empty"

  resolve
  [ -z "${MIDWAY}" ] || die "upstream is midway through a publication: ${MIDWAY}"
  local want have
  want="$(sed -E 's/^v//; s/\+[0-9]+$//' <<< "${tag}")"
  have="$(upstream_version "$(manifest_version upmpdcli)")"
  [ "${want}" = "${have}" ] || die "tag ${tag} is for upmpdcli ${want}, upstream now has ${have}"

  mkdir -p "${out}/debs" "${out}/sources"
  local pkg ver arch repo fn sha src sver
  while IFS=$'\t' read -r pkg ver arch repo fn sha src sver; do
    log "deb     ${fn##*/}"
    download "${UPSTREAM}/${repo}/${fn}" "${out}/debs/${fn##*/}"
    verify_sha256 "${out}/debs/${fn##*/}" "${sha}"
  done < "${MANIFEST}"

  local files dir name tarball
  while IFS=$'\t' read -r src sver; do
    files="$(source_files "${src}" "${sver}")"
    if [ -n "${files}" ]; then
      while IFS=$'\t' read -r dir sha name; do
        log "source  ${name}"
        download "${UPSTREAM}/${dir}/${name}" "${out}/sources/${name}"
        verify_sha256 "${out}/sources/${name}" "${sha}"
      done <<< "${files}"
    else
      # The upstream repositories only keep the latest source package; fall
      # back to the signed release tarball for binaries that were not rebuilt.
      tarball="${src}-$(upstream_version "${sver}").tar.gz"
      log "source  ${tarball} (no source package ${src} ${sver} upstream)"
      download "${UPSTREAM}/${tarball}" "${out}/sources/${tarball}"
      download "${UPSTREAM}/${tarball}.asc" "${WORK}/${tarball}.asc"
      gpgv --quiet --keyring "${KEYRING}" "${WORK}/${tarball}.asc" "${out}/sources/${tarball}" 2>/dev/null \
        || die "bad signature on ${tarball}"
    fi
  done < <(cut -f7,8 "${MANIFEST}" | sort -u)

  write_notes > "${out}/notes.md"
}

write_notes() {
  cat <<EOF
Upstream trixie builds from lesbonscomptes.com, mirrored unchanged: amd64
from the debian repository, arm64 and armhf (ARMv6) from the raspbian
repository. The InRelease signatures (key \`${KEY_FPR}\`) and the
SHA256 of every file were checked.

EOF
  package_table
  cat <<EOF

The sources of these binaries (Debian source packages, or the signed upstream
release tarball when the source package is no longer published) are attached.
EOF
}

package_table() {
  echo '| Package | Version | Architectures |'
  echo '|---------|---------|---------------|'
  awk -F'\t' '
    { key = $1 "\t" $2; if (!(key in arches)) order[++n] = key; arches[key] = arches[key] (arches[key] == "" ? "" : ", ") $3 }
    END { for (i = 1; i <= n; i++) { split(order[i], k, "\t"); print "| " k[1] " | " k[2] " | " arches[order[i]] " |" } }' "${MANIFEST}"
}

case "${1:-}" in
  check) shift; cmd_check "$@" ;;
  plan)  shift; cmd_plan "$@" ;;
  fetch) shift; cmd_fetch "$@" ;;
  *) sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
