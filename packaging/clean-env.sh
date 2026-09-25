# shellcheck shell=bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sourced first by every script of the build and of the lock gate (make-deb.sh, build-venv.sh,
# lock-deps.sh, the lock tests): the caller's shell setup does not decide which programs run or
# how Python, pip, uv and git behave. A developer's activated venv, a project .venv, conda, a
# PYTHONPATH or a pip/uv mirror setting would otherwise put programs of a venv filled from some
# lock in front of the gate's own tools (a wheel can ship its own diff, awk or python3 into
# bin/, and a .pth runs in every interpreter of its venv), or answer the gate's questions from
# another index. The scripts call python as /usr/bin/python3 -I and give uv the interpreter
# explicitly, so no venv is ever looked for.
#
# What stays is the caller's to set: HOME, TMPDIR, locale, proxies, DEB_BUILD_OPTIONS. BASH_ENV
# is removed for the scripts started from here; the one that sourced this file has run it
# already (whoever sets it, or LD_PRELOAD, runs code in the build by definition).
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
for _v in $(compgen -e); do
    case "$_v" in
        VIRTUAL_ENV | VIRTUAL_ENV_PROMPT | CONDA_* | PYTHON* | UV_* | PIP_* | GIT_* | BASH_ENV | ENV)
            unset "$_v" ;;
    esac
done
unset _v
# No pip configuration file at all (/etc/pip.conf, ~/.config/pip, a venv's pip.conf); uv reads
# none either and never downloads a Python of its own.
export PIP_CONFIG_FILE=/dev/null PIP_DISABLE_PIP_VERSION_CHECK=1
export UV_NO_CONFIG=1 UV_PYTHON_DOWNLOADS=never
