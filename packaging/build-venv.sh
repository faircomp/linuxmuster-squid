#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds the hermetic Python venv of linuxmuster-squid at the path given as $1. debian/rules
# (override_dh_auto_install) calls it with debian/linuxmuster-squid/opt/linuxmuster-squid/venv:
# the venv is built inside the package tree, without root, and debian/venv-relocate then makes
# it correct for its installed path /opt/linuxmuster-squid/venv. The version of the lmnsquid
# wheel is the top entry of debian/changelog (controlplane/setup.py reads it).
set -euo pipefail

VENV="${1:?usage: build-venv.sh <venv directory>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

# Every third-party file in the package comes from a lock file with sha256 hashes: pip
# resolves nothing and never takes "the newest" (--require-hashes --no-deps), so two builds
# of the same commit ship the same dependencies. Wheels only (--only-binary :all:): the
# locks list sdist hashes too, and building an sdist would fetch its build backend from
# PyPI without any hash and run it here. Locks and how to refresh them:
# packaging/lock-deps.sh.
echo "== lmnsquid wheel (throwaway build venv, not shipped) =="
python3 -m venv "$BUILD/venv"
"$BUILD/venv/bin/pip" install --quiet --require-hashes --no-deps --only-binary :all: \
    -r "$ROOT/packaging/requirements-build.lock"
# No build isolation: it would fetch an unpinned setuptools from PyPI to run here.
"$BUILD/venv/bin/pip" wheel --quiet --no-deps --no-index --no-build-isolation \
    -w "$BUILD/wheel" "$ROOT/controlplane"

echo "== venv @ $VENV =="
rm -rf "$VENV"
mkdir -p "$(dirname "$VENV")"
python3 -m venv "$VENV"
"$VENV/bin/pip" install --quiet --require-hashes --no-deps --only-binary :all: \
    -r "$ROOT/controlplane/requirements.lock"
# By name from the wheel directory, not by path: a path install records the (random)
# build directory in direct_url.json, which would make two builds differ.
"$VENV/bin/pip" install --quiet --no-deps --no-index --only-binary :all: \
    --find-links "$BUILD/wheel" lmnsquid
"$VENV/bin/pip" check
# The venv holds exactly the lock plus lmnsquid. Every requirement line of the lock counts,
# whatever it looks like, and anything pip freeze lists other than name==version (a direct
# URL, a local path) stops the build instead of being filtered away.
FREEZE="$("$VENV/bin/pip" freeze --all --exclude lmnsquid)"
if grep -v '^[A-Za-z0-9][A-Za-z0-9._-]*==[^ ]*$' <<< "$FREEZE"; then
    echo "venv holds the package(s) above, which are not plain name==version pins" >&2
    exit 1
fi
diff -u \
    <(grep -vE '^(#|[[:space:]]|$)' "$ROOT/controlplane/requirements.lock" | cut -d' ' -f1 \
        | LC_ALL=C sort) \
    <(awk -F'==' '{ n = tolower($1); gsub(/[-_.]+/, "-", n); print n "==" $2 }' <<< "$FREEZE" \
        | LC_ALL=C sort)
