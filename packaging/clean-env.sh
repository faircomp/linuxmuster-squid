# shellcheck shell=bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sourced first, before any cd, by every script of the build and of the lock gate (make-deb.sh,
# build-venv.sh, lock-deps.sh, the lock tests), so that a developer's activated venv, a project
# .venv, conda, a PYTHONPATH or a pip/uv mirror setting cannot put programs of a venv filled from
# some lock in front of the gate's own tools (a wheel can ship its own diff, awk or python3 into
# bin/, and a .pth runs in every interpreter of its venv) or answer the gate from another index.
#
# What it does, for the sourcing script and everything started from it:
#  * PATH=/usr/sbin:/usr/bin:/sbin:/bin (the scripts also set it as their first line);
#  * removes VIRTUAL_ENV, VIRTUAL_ENV_PROMPT, CONDA_*, PYTHON*, UV_*, PIP_* (PIP_REQUIREMENT and
#    PIP_CONSTRAINT among them), GIT_*, PERL5OPT, PERL5LIB, PERLLIB, PERL5DB (dpkg and debhelper
#    are Perl), BASH_ENV, ENV and CDPATH, and the shell functions defined at this point (also
#    those the caller exported; called through `builtin`, so a function named compgen or unset
#    cannot keep the others);
#  * no pip configuration file at all (/etc/pip.conf, ~/.config/pip, a venv's pip.conf); uv reads
#    none either and never downloads a Python. The scripts call python as /usr/bin/python3 -I and
#    give uv the interpreter and the index explicitly, so no venv is ever looked for.
#
# What it leaves to the caller on purpose, among others: HOME, TMPDIR, the locale, proxies and CA
# bundles (HTTP(S)_PROXY, NO_PROXY, SSL_CERT_FILE, REQUESTS_CA_BUNDLE: they decide how PyPI is
# reached, the hashes still decide what is installed), DEB_*, DH_* and SOURCE_DATE_EPOCH (dpkg's
# and debhelper's own knobs), and git's system and global configuration (make-deb.sh runs only
# reading git commands, with fsmonitor, hooks and pager off).
#
# What it cannot undo: the shell that sources it has already read the caller's BASH_ENV, imported
# the caller's exported functions (used for the lines before this file; one named `builtin`
# survives this file too) and applied SHELLOPTS and BASHOPTS; LD_PRELOAD and LD_LIBRARY_PATH reach
# every program. Whoever sets those in the caller's environment runs code as the caller anyway;
# none of it comes from a lock.
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
for _v in $(builtin compgen -A function); do builtin unset -f "$_v"; done
for _v in $(compgen -e); do
    case "$_v" in
        VIRTUAL_ENV | VIRTUAL_ENV_PROMPT | CONDA_* | PYTHON* | UV_* | PIP_* | GIT_* | \
        PERL5OPT | PERL5LIB | PERLLIB | PERL5DB | BASH_ENV | ENV | CDPATH)
            unset "$_v" ;;
    esac
done
unset _v CDPATH
export PIP_CONFIG_FILE=/dev/null PIP_DISABLE_PIP_VERSION_CHECK=1
export UV_NO_CONFIG=1 UV_PYTHON_DOWNLOADS=never
