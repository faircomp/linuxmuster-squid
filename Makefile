# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# `make deb` is the uniform build entry point of Kevin's linuxmuster.net packages
# (linuxmusterDEV/docs/paket-konventionen.md). It runs dpkg-buildpackage; the .deb, .changes,
# .buildinfo, .dsc and the source tarball land one level ABOVE the source tree. debian/rules
# overrides the dh_auto_* steps, so debhelper never calls back into this Makefile. No root
# needed (Rules-Requires-Root: no); needs the Build-Depends of debian/control and network
# access to PyPI (the hash-pinned locks). Build like CI does, in the digest-pinned build image
# (IMG_LMN73 in .github/workflows/ci.yml), from a directory whose parent may receive the
# build results:
#   docker run --rm -v "$PWD/..":/build -w /build/$(basename "$PWD") <IMG_LMN73> \
#     bash -c 'apt-get update -qq && apt-get build-dep -y -qq . && make deb'
#
# Source package: what git tracks and nothing else. In a git checkout the tracked files (as
# they are in the working tree) are copied into a temporary directory and built there, so
# nothing untracked or gitignored (secrets under deploy/, .env, build/, venvs, caches, agent
# settings) can reach the source tarball, and the checkout is left untouched. Left out on
# purpose: .github/ and .claude/ (CI and developer tooling) and dpkg-source's default ignore
# list (.gitignore and the like; the bare -I keeps that list, an -I<pattern> alone would
# replace it). The copy gets fresh mtimes (tar --touch): dpkg clamps only mtimes newer than
# the changelog date, so older ones of a long-lived checkout would reach the .deb, and two
# checkouts of the same commit would build different packages. Without git (an unpacked
# source package) the tree is built as it is.
.PHONY: all deb clean

# bash with pipefail: a failing `git ls-files` or tar in the copy pipeline stops the build.
SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

PKG := linuxmuster-squid
BUILDPACKAGE := dpkg-buildpackage -us -uc -I -I.github -I.claude
GIT := git -c safe.directory='$(CURDIR)' -C '$(CURDIR)'

all: deb

deb:
	@if top=$$($(GIT) rev-parse --show-toplevel 2>/dev/null) && [ "$$top" = '$(CURDIR)' ]; then \
		tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; \
		mkdir "$$tmp/$(PKG)"; \
		$(GIT) ls-files -z \
			| tar -C '$(CURDIR)' --null --no-recursion --ignore-failed-read -T - -cf - \
			| tar -C "$$tmp/$(PKG)" --touch -xf -; \
		echo "make deb: building the $$($(GIT) ls-files | wc -l) tracked files in $$tmp/$(PKG)"; \
		(cd "$$tmp/$(PKG)" && $(BUILDPACKAGE)); \
		mv "$$tmp"/$(PKG)_* ..; \
	else \
		echo "make deb: not a git checkout, building the tree as it is"; \
		$(BUILDPACKAGE) -tc; \
	fi

clean:
	debian/rules clean
