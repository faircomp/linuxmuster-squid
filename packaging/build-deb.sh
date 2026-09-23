#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds the linuxmuster-squid .deb with a hermetic Python venv under
# /opt/linuxmuster-squid/venv (built at the target path so the shebangs are correct)
# + systemd unit + maintainer scripts. RUN AS ROOT (or `make deb` in the lmndev-runner
# container). The version is the top entry of debian/changelog, the single version
# source; VERSION=<x> in the environment overrides only the .deb metadata (the venv's
# Python package always carries the changelog version via controlplane/setup.py).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-$(dpkg-parsechangelog -l "$ROOT/debian/changelog" -S Version)}"
case "$VERSION" in
    ""|*[!0-9A-Za-z.+~-]*) echo "invalid VERSION: '$VERSION'" >&2; exit 1 ;;
esac
VENV=/opt/linuxmuster-squid/venv
STAGE="$(mktemp -d)"
BUILD="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$BUILD"' EXIT

# Every third-party file in the package comes from a lock file with sha256 hashes: pip
# resolves nothing and never takes "the newest" (--require-hashes --no-deps), so two builds
# of the same commit ship the same dependencies. Locks and how to refresh them:
# packaging/lock-deps.sh.
echo "== lmnsquid wheel (throwaway build venv, not shipped) =="
python3 -m venv "$BUILD/venv"
"$BUILD/venv/bin/pip" install --quiet --require-hashes --no-deps \
    -r "$ROOT/packaging/requirements-build.lock"
# No build isolation: it would fetch an unpinned setuptools from PyPI to run as root here.
"$BUILD/venv/bin/pip" wheel --quiet --no-deps --no-index --no-build-isolation \
    -w "$BUILD/wheel" "$ROOT/controlplane"

echo "== venv @ $VENV =="
rm -rf "$VENV"
mkdir -p /opt/linuxmuster-squid
python3 -m venv "$VENV"
"$VENV/bin/pip" install --quiet --require-hashes --no-deps -r "$ROOT/controlplane/requirements.lock"
# By name from the wheel directory, not by path: a path install records the (random)
# build directory in direct_url.json, which would make two builds differ.
"$VENV/bin/pip" install --quiet --no-deps --no-index --find-links "$BUILD/wheel" lmnsquid
"$VENV/bin/pip" check
# The venv holds exactly the lock plus lmnsquid (pip freeze prints names unnormalized).
lock_pins() { grep -E '^[a-z0-9]' "$ROOT/controlplane/requirements.lock" | sed 's/ .*//'; }
venv_pins() {
    "$VENV/bin/pip" freeze --all --exclude lmnsquid \
        | awk -F'==' '{ n = tolower($1); gsub(/[-_.]+/, "-", n); print n "==" $2 }' | LC_ALL=C sort
}
diff -u <(lock_pins | LC_ALL=C sort) <(venv_pins)

echo "== staging tree =="
mkdir -p "$STAGE/opt/linuxmuster-squid" "$STAGE/lib/systemd/system" "$STAGE/DEBIAN" \
         "$STAGE/usr/bin" "$STAGE/usr/share/linuxmuster-squid/scripts"
cp -a "$VENV" "$STAGE/opt/linuxmuster-squid/venv"
# Operator CLI onto PATH: the venv keeps the hermetic interpreter, the packaged symlink
# makes `lmnsquid` available without a manual `ln -s` (dpkg removes it on purge).
ln -s /opt/linuxmuster-squid/venv/bin/lmnsquid "$STAGE/usr/bin/lmnsquid"
# Admin scripts the docs refer to (run on the DC / from cron), so an admin with only the
# .deb has them: docs/install.md, docs/keytab-and-dns.md, docs/operations.md.
for s in provision-keytab.sh discover-ad-facts.sh blocklist-refresh.sh; do
    install -m 0755 "$ROOT/scripts/$s" "$STAGE/usr/share/linuxmuster-squid/scripts/$s"
done
cp "$ROOT/packaging/systemd/linuxmuster-squid.service" \
   "$STAGE/lib/systemd/system/linuxmuster-squid.service"
sed "s/@VERSION@/$VERSION/" "$ROOT/packaging/debian/control" > "$STAGE/DEBIAN/control"
for f in postinst prerm postrm; do
    cp "$ROOT/packaging/debian/$f" "$STAGE/DEBIAN/$f"
    chmod 0755 "$STAGE/DEBIAN/$f"
done
# md5sums (what dh_md5sums writes): every regular file outside DEBIAN/, paths relative to
# the package root, so `dpkg --verify linuxmuster-squid` can check the installed files.
( cd "$STAGE" && find . -type f ! -path './DEBIAN/*' -printf '%P\0' | LC_ALL=C sort -z \
    | xargs -0r md5sum > DEBIAN/md5sums )
chmod 0644 "$STAGE/DEBIAN/md5sums"

OUT="$ROOT/linuxmuster-squid_${VERSION}_all.deb"
echo "== dpkg-deb -> $OUT =="
dpkg-deb --build --root-owner-group "$STAGE" "$OUT"
echo "== built $OUT =="

# Signing (production): apt does NOT verify individual .deb signatures, but rather the
# signed repo `Release` (InRelease / Release.gpg). So add the .deb into the lmn73 **reprepro**
# repo (deb.linuxmuster.net); reprepro signs the `Release` with the linuxmuster
# GPG key (reprepro `SignWith`). NO `dpkg-sig` per package. Requires the real key + repo access
# (human gate). Verified against wiki.debian.org/DebianRepository/SetupWithReprepro + deb.linuxmuster.net.
