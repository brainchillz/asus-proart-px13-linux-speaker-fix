#!/usr/bin/env bash
#
# Re-apply patches/ onto a different kernel version's tas2783-sdw.c and
# refresh this directory's snapshot. Argument: path to an extracted
# linux-source tree (the dir containing sound/soc/codecs/).
#
# After regenerating: build-test against the target kernel headers, bump
# PACKAGE_VERSION in dkms.conf, re-run ../fix-px13-audio.sh.

set -euo pipefail

SRC="${1:?usage: $0 <extracted-linux-source-dir>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

codec="$SRC/sound/soc/codecs"
[ -f "$codec/tas2783-sdw.c" ] || { echo "no $codec/tas2783-sdw.c" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "$codec/tas2783-sdw.c" "$codec/tas2783.h" "$work/"

cd "$work"
for p in "$HERE"/patches/*.patch; do
  echo "==> applying $(basename "$p")"
  patch -p4 --no-backup-if-mismatch < "$p"
done

cp tas2783-sdw.c tas2783.h "$HERE/"
echo "==> updated $HERE/tas2783-sdw.c (+ tas2783.h)"
echo "    build-test: make -C /lib/modules/<version>/build M=$HERE modules"
