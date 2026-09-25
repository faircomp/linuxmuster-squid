# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# `make deb` is the uniform build entry point of Kevin's linuxmuster.net packages
# (linuxmusterDEV/docs/paket-konventionen.md). It runs dpkg-buildpackage (packaging/make-deb.sh);
# the .deb, .changes, .buildinfo, .dsc and the source tarball land one level ABOVE the source
# tree. debian/rules overrides the dh_auto_* steps, so debhelper never calls back into this
# Makefile. No root needed (Rules-Requires-Root: no); needs the Build-Depends of debian/control,
# git and network access to PyPI (the hash-pinned locks). Build like CI does, in the
# digest-pinned build image (IMG_LMN73 in .github/workflows/ci.yml), from a directory whose
# parent may receive the build results. As root in the container (-u root): the image's own user
# `build` cannot run apt-get; the results in the parent directory then belong to root. Mount the
# repository's git directory as well, at its own path and read-only: in a git worktree
# (linuxmusterDEV `bin/wt`) the checkout's .git only points there, and without it make deb stops
# instead of building (in a plain clone it is the checkout's own .git, mounted once more):
#   GITDIR=$(git rev-parse --path-format=absolute --git-common-dir)
#   docker run --rm -u root -v "$PWD/..":/build -v "$GITDIR:$GITDIR:ro" -w /build/$(basename "$PWD") \
#     <IMG_LMN73> bash -c 'apt-get update -qq && apt-get build-dep -y -qq . && make deb'
#
# Source package: what git tracks and nothing else, exported with git's file modes into a
# temporary directory and built there (packaging/make-deb.sh), so nothing untracked or
# gitignored (secrets under deploy/, .env, build/, venvs, caches, agent settings) can reach the
# source tarball, and the checkout is left untouched. Uncommitted changes are built as they are
# in the working tree, under the changelog's version: make deb warns and lists every modified,
# deleted, staged, removed or new (not added, so not built) file. Left out on purpose: .github/
# and .claude/ (CI and developer tooling) and dpkg-source's default ignore list (.gitignore and
# the like). Without any .git (an unpacked source package) the tree is built as it is; a .git
# that git cannot use stops the build. The build runs with a fixed PATH; the caller's venv,
# PYTHON*, UV_*, PIP_*, GIT_*, CDPATH and BASH_ENV settings and exported shell functions are
# removed first thing (packaging/clean-env.sh, which also names what it leaves to the caller and
# what it cannot undo).
.PHONY: all deb clean

# BASH_ENV would run in every recipe shell before the build could clean its environment.
unexport BASH_ENV ENV

all: deb

deb:
	/bin/bash packaging/make-deb.sh

clean:
	debian/rules clean
