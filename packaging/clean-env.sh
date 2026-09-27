# shellcheck shell=bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sourced first by every script that checks the lock files or builds (make-deb.sh,
# build-venv.sh, lock-deps.sh, run.sh, the lock tests), before anything else runs, as
#     POSIXLY_CORRECT=1
#     . "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/clean-env.sh"
# It restarts the sourcing script under `env -i` with an ALLOWLIST, through `/bin/bash -p`, so
# nothing of the caller's environment reaches the script or anything it starts unless it is named
# here: no activated venv, PYTHON*, pip/uv settings, Perl, make, tar or loader variables, no
# exported shell functions, no SHELLOPTS, BASHOPTS or BASH_ENV, whatever their names.
#
# The allowlist (nothing else is passed):
#  * set to fixed values: PATH=/usr/sbin:/usr/bin:/sbin:/bin, LC_ALL=C.UTF-8;
#  * passed as the caller has them, if set: HOME and TMPDIR; the proxies http_proxy,
#    https_proxy, no_proxy, HTTP_PROXY, HTTPS_PROXY, NO_PROXY; the CA bundles SSL_CERT_FILE,
#    SSL_CERT_DIR, REQUESTS_CA_BUNDLE, PIP_CERT (they decide how PyPI is reached; the hashes still
#    decide what is installed); no pip location (the repository passes none);
#  * the variables the repository's scripts pass to each other: LMNSQUID_ALLOW_SKIP and
#    LMNSQUID_ALLOW_REAL (run.sh), LOCK_GATES_VERBOSE and LOCK_GATES_NESTED (lock_gates.sh);
#  * LMNSQUID_CLEAN_ENV=1, only for the restarted process: it stops a second restart and is
#    removed right after the check, so it never reaches another script.
# After the restart this file sets PIP_CONFIG_FILE=/dev/null, PIP_DISABLE_PIP_VERSION_CHECK=1,
# UV_NO_CONFIG=1 and UV_PYTHON_DOWNLOADS=never: no pip configuration file is read, uv reads none
# and never downloads a Python. The scripts call python as /usr/bin/python3 -I and give uv the
# interpreter and the index explicitly.
#
# Before the restart only the two lines above run in the caller's shell: an assignment that turns
# on POSIX mode (POSIX special builtins such as `.` and `exec` then take precedence over functions
# of the same name), `.` of this file and, here, keywords, expansions and `exec`. So no exported
# function of the caller runs, whatever its name (`builtin`, `set`, `export`, `.`, `exec`,
# `dirname` included). A shell that already runs with -p (bash -p, the scripts' `#!/bin/bash -p`,
# the Makefile's recipe) is checked instead: it is restarted unless every exported variable is
# on the allowlist (a -p shell has imported no functions and ignored SHELLOPTS and BASHOPTS).
#
# What it cannot undo, because it ran before the restart: the caller's first bash itself when a
# script is started as `bash <script>` (its BASH_ENV, and SHELLOPTS such as noexec or onecmd,
# which stop it from reading the script at all, so it ends without checking anything: start the
# scripts as `/bin/bash -p <script>`, as ./<script>, through make deb or run.sh, which do so),
# the make that runs `make deb` (it reads MAKEFILES, MAKEFLAGS, GNUMAKEFLAGS itself: `make -i
# deb` ends with 0 although the build failed, but no package is written) and LD_PRELOAD for that
# first bash and for /usr/bin/env. Whoever sets those in the caller's environment runs code as
# the caller anyway; none of it comes from a lock.
if [[ $- == *p* ]]; then
    # bash -p: no function of the caller was imported, so compgen is the builtin
    _lmn_dirty=
    for _lmn_v in $(compgen -e); do
        case "$_lmn_v" in
            PATH | LC_ALL | HOME | TMPDIR | http_proxy | https_proxy | no_proxy | HTTP_PROXY | \
            HTTPS_PROXY | NO_PROXY | SSL_CERT_FILE | SSL_CERT_DIR | REQUESTS_CA_BUNDLE | PIP_CERT | \
            LMNSQUID_ALLOW_SKIP | LMNSQUID_ALLOW_REAL | LOCK_GATES_VERBOSE | LOCK_GATES_NESTED | \
            LMNSQUID_CLEAN_ENV | PIP_CONFIG_FILE | PIP_DISABLE_PIP_VERSION_CHECK | UV_NO_CONFIG | \
            UV_PYTHON_DOWNLOADS | PWD | OLDPWD | SHLVL) ;;
            *) _lmn_dirty+=" $_lmn_v" ;;
        esac
    done
else
    _lmn_dirty=" (not a bash -p shell)"
fi
if [[ -n $_lmn_dirty ]]; then
    if [[ $- == *p* && ${LMNSQUID_CLEAN_ENV:-} == 1 ]]; then
        echo "clean-env.sh: the restarted environment still holds:$_lmn_dirty" >&2
        exit 2
    fi
    _lmn_keep=(PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C.UTF-8 LMNSQUID_CLEAN_ENV=1)
    for _lmn_v in HOME TMPDIR http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY \
        SSL_CERT_FILE SSL_CERT_DIR REQUESTS_CA_BUNDLE PIP_CERT LMNSQUID_ALLOW_SKIP \
        LMNSQUID_ALLOW_REAL LOCK_GATES_VERBOSE LOCK_GATES_NESTED; do
        if [[ -n ${!_lmn_v+x} ]]; then _lmn_keep+=("$_lmn_v=${!_lmn_v}"); fi
    done
    exec /usr/bin/env -i "${_lmn_keep[@]}" /bin/bash -p "${BASH_SOURCE[1]}" "$@"
fi
# From here on: bash -p, the allowlisted environment, bash's own mode again.
unset POSIXLY_CORRECT LMNSQUID_CLEAN_ENV _lmn_dirty _lmn_keep _lmn_v
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C.UTF-8
export PIP_CONFIG_FILE=/dev/null PIP_DISABLE_PIP_VERSION_CHECK=1
export UV_NO_CONFIG=1 UV_PYTHON_DOWNLOADS=never
