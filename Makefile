# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# `make deb` is the uniform build entry point of Kevin's linuxmuster.net packages
# (linuxmusterDEV/docs/paket-konventionen.md). dpkg-buildpackage writes the .deb, .changes,
# .buildinfo, .dsc and the source tarball one level ABOVE the source tree; -tc cleans the
# tree afterwards. debian/rules overrides the dh_auto_* steps, so debhelper never calls back
# into this Makefile. No root needed (Rules-Requires-Root: no); needs the Build-Depends of
# debian/control and network access to PyPI (the hash-pinned locks). Build like CI does, in
# the digest-pinned build image (IMG_LMN73 in .github/workflows/ci.yml), from a directory
# whose parent may receive the build results:
#   docker run --rm -v "$PWD/..":/build -w /build/$(basename "$PWD") <IMG_LMN73> \
#     bash -c 'apt-get update -qq && apt-get build-dep -y -qq . && make deb'
#
# Source tarball: the bare -I keeps dpkg-source's default ignore list (.git, .gitignore,
# editor backups, ...); an -I<pattern> alone would replace it. The patterns match in any
# depth and keep what a working checkout holds besides the repository out of it: the
# development venv, tool caches, local agent settings (they may carry tokens), crabbox state,
# keytabs and packages of earlier builds.
.PHONY: all deb clean

all: deb

deb:
	dpkg-buildpackage -us -uc -tc -I -I.github -I.claude -I.crabbox -I.venv \
		-I.mypy_cache -I.ruff_cache -I.pytest_cache -I__pycache__ -I'*.keytab' -I'*.deb'

clean:
	debian/rules clean
