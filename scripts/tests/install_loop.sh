#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Regression guard for the postinst (CI install-smoke; by hand in the lmndev-runner
# container): configure the SAME .deb many times in a row. The 7.3.1-7.3.3 postinst
# committed to the instance store as root and chowned the tree afterwards, racing the
# detached `git maintenance` that git >= 2.47 starts after a commit; the configure failed
# only sometimes ("chown: ... maintenance.lock: No such file or directory"), so a single
# install proves nothing.
#   phase 1: N x purge + fresh install (the postinst creates the repository and commits)
#   phase 2: the store gets the history of a store in use (SEED commits by lmnsquid, as the
#            service commits every create/edit/update/rm), then N x reinstall over itself,
#            alternating with dpkg-reconfigure, each after a root-owned record file was
#            dropped into the store (as a restore from backup does), so the postinst has
#            something to commit -- no commit, nothing to race.
# The history matters: the window grows with objects/, which chown walks while the detached
# maintenance holds its lock. Measured with the old postinst (container, git 2.55): 0 of 100
# fresh installs failed, but 37 of 100 reinstalls, all once the store had ~40 commits; with
# the defaults below, 65 of 75 reinstalls in five runs (the fixed postinst: 0 of 150).
# After every configure: the package is "ii", everything under the config and state
# directories belongs to lmnsquid, the history is kept and grew by the postinst's commit,
# and no git maintenance/gc process outlived the configure.
#
# RUN AS ROOT, with the package's dependencies installed:
#   bash scripts/tests/install_loop.sh <deb> [cycles per phase, default 15]
# KEEP_GOING=1 counts failures instead of stopping at the first (to measure a race); a
# failed configure is then finished with `dpkg --configure -a`, as an admin would.
# SEED=<n> sets the size of the history before phase 2 (default 50).
set -uo pipefail

DEB="${1:?usage: install_loop.sh <deb> [cycles per phase]}"
N="${2:-15}"
KEEP_GOING="${KEEP_GOING:-0}"
SEED="${SEED:-50}"
PKG=linuxmuster-squid
INST=/var/lib/linuxmuster-squid/instances
conf_fail=0 check_fail=0 repaired=0

summary() {
    echo "== install loop ($(git --version)): $N purge+install and $N reinstall/reconfigure" \
         "cycles (history $SEED), $conf_fail configure failure(s), $check_fail check failure(s)," \
         "$repaired finished by 'dpkg --configure -a', ${SECONDS}s =="
}

# $1 = kind, $2 = message. Stops the loop unless KEEP_GOING=1.
fail() {
    echo "FAIL [$1] $2" >&2
    if [ "$KEEP_GOING" != 1 ]; then summary; exit 1; fi
}

# git in the store as its owner: a root `git` could write root-owned files into it.
# XDG_CONFIG_HOME may point into root's home (GitHub runners set it), as in the postinst.
as_owner() { runuser -u lmnsquid -- env -u XDG_CONFIG_HOME "$@"; }
store_git() { as_owner git -C "$INST" "$@"; }

# $1 = label, rest = the dpkg command that configures the package.
configure() {
    local label=$1 out
    shift
    if out=$("$@" 2>&1); then return 0; fi
    conf_fail=$((conf_fail + 1))
    printf '%s\n' "$out" | grep -E 'chown|error|rror processing' | head -n 4 >&2
    fail configure "$label"
    if dpkg --configure -a >/dev/null 2>&1; then repaired=$((repaired + 1)); fi
}

# $1 = label, $2 = the commit count the store must have now.
check() {
    local label=$1 want=$2 status foreign have left
    status=$(dpkg-query -W -f='${db:Status-Abbrev}' "$PKG" 2>/dev/null)
    foreign=$(find /etc/linuxmuster-squid /var/lib/linuxmuster-squid ! -user lmnsquid \
                   -printf '%u:%p ' 2>/dev/null | cut -c1-300)
    have=$(store_git rev-list --count HEAD 2>/dev/null)
    left=$(pgrep -a -f '^git (maintenance|gc)' | head -n 3)
    if [ "$status" != "ii " ] || [ -n "$foreign" ] || [ "$have" != "$want" ] || [ -n "$left" ]; then
        check_fail=$((check_fail + 1))
        fail check "$label: status='$status' commits=$have (want $want)${foreign:+ foreign-owned: $foreign}${left:+ running: $left}"
    fi
}

[ "$(id -u)" = 0 ] || { echo "install_loop.sh: run as root" >&2; exit 2; }
[ -f "$DEB" ] || { echo "install_loop.sh: no such file: $DEB" >&2; exit 2; }

for i in $(seq 1 "$N"); do
    dpkg --purge "$PKG" >/dev/null 2>&1 || fail purge "cycle $i: dpkg --purge"
    configure "fresh install $i" dpkg -i "$DEB"
    check "fresh install $i" 1
done

# The seed itself must not leave a maintenance process behind for the next check to find.
# shellcheck disable=SC2016  # expanded by the inner sh
as_owner sh -c 'cd "$1" && for j in $(seq 1 "$2"); do
        printf "# history %s\n" "$j" > "history-$j.yaml"
        git add -- "history-$j.yaml" &&
            git -c maintenance.auto=false commit -q -m "history $j" || exit 1
    done' sh "$INST" "$SEED" || fail seed "could not commit the history as lmnsquid"
check "history of $SEED commits" $((SEED + 1))

for i in $(seq 1 "$N"); do
    before=$(store_git rev-list --count HEAD 2>/dev/null)
    printf '# install loop record %s\n' "$i" > "$INST/install-loop-$i.yaml"
    if [ $((i % 2)) = 1 ]; then
        configure "reinstall $i" dpkg -i "$DEB"
    else
        configure "dpkg-reconfigure $i" dpkg-reconfigure -f noninteractive "$PKG"
    fi
    check "reinstall/reconfigure $i" $((before + 1))
done

summary
[ "$conf_fail" = 0 ] && [ "$check_fail" = 0 ]
