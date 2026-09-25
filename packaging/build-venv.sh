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
LOCK_DEPS="$ROOT/packaging/lock-deps.sh"
LOCK="$ROOT/controlplane/requirements.lock"

# Every third-party file in the package comes from a lock file with sha256 hashes: pip
# resolves nothing and never takes "the newest" (--require-hashes --no-deps), so two builds
# of the same commit ship the same dependencies. Wheels only (--only-binary :all:): the
# locks list sdist hashes too, and building an sdist would fetch its build backend from
# PyPI without any hash and run it here. Locks and how to refresh them:
# packaging/lock-deps.sh.
#
# The locks pass the same gate here as in the fast tier, so no build (`make deb`, the release)
# can ship a lock that CI would reject, whether or not CI ran on that commit. First their
# grammar, offline, before pip reads either file: pip would also install an indented
# `name @ url#sha256=...` line or follow an index option. Then, with the uv the build lock
# pins, the full check, which needs PyPI: the pins still match their inputs (an extra pin with
# valid hashes passes pip and the freeze gate below), every pin has a target wheel, and every
# hash is one PyPI lists for its pin (a changed hash of a file pip never downloads passes pip).
echo "== lock files: grammar =="
bash "$LOCK_DEPS" --lint
echo "== build venv (throwaway, not shipped): lock check, lmnsquid wheel =="
python3 -m venv "$BUILD/venv"
"$BUILD/venv/bin/pip" install --quiet --require-hashes --no-deps --only-binary :all: \
    -r "$ROOT/packaging/requirements-build.lock"
PATH="$BUILD/venv/bin:$PATH" UV_CACHE_DIR="$BUILD/uv-cache" bash "$LOCK_DEPS" --check
# No build isolation: it would fetch an unpinned setuptools from PyPI to run here.
"$BUILD/venv/bin/pip" wheel --quiet --no-deps --no-index --no-build-isolation \
    -w "$BUILD/wheel" "$ROOT/controlplane"
WHEELS=("$BUILD"/wheel/lmnsquid-*.whl)
if [ "${#WHEELS[@]}" != 1 ] || [ ! -f "${WHEELS[0]}" ]; then
    echo "expected exactly one lmnsquid wheel in $BUILD/wheel" >&2; exit 1
fi
OWN="${WHEELS[0]##*/lmnsquid-}"
OWN="lmnsquid==${OWN%%-*}"

echo "== venv @ $VENV =="
rm -rf "$VENV"
mkdir -p "$(dirname "$VENV")"
python3 -m venv "$VENV"
"$VENV/bin/pip" install --quiet --require-hashes --no-deps --only-binary :all: -r "$LOCK"
# By name from the wheel directory, not by path: a path install records the (random)
# build directory in direct_url.json, which would make two builds differ.
"$VENV/bin/pip" install --quiet --no-deps --no-index --only-binary :all: \
    --find-links "$BUILD/wheel" lmnsquid
"$VENV/bin/pip" check
# The venv holds exactly the lock plus lmnsquid. Every requirement line of the lock counts,
# whatever it looks like, and anything pip freeze lists other than name==version (a direct
# URL, a local path) stops the build instead of being filtered away. pip freeze runs in an
# assignment, not in a pipe or process substitution, so its failure stops the build as well.
echo "== venv = lock + $OWN =="
FREEZE="$("$VENV/bin/pip" freeze --all)"
bash "$LOCK_DEPS" --verify-freeze "$LOCK" "$OWN" <<< "$FREEZE"
