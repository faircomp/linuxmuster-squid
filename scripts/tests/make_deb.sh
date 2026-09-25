#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Regression test for `make deb` (packaging/make-deb.sh): what the source package holds, what a
# build takes from the checkout and from the shell it is started in (linuxmusterDEV
# work/verification/cold-debian-squid-r2.md F1, F3, F4, F6; cold-debian-radius-r2.md F6, F7).
# Fixtures are git repositories made of the tracked files of this tree, as they are now.
#
#  * full: one real `make deb` of a hostile checkout, and its .deb, .dsc and source tarball must
#    be byte-identical to the reference. The checkout is a git worktree of a repository that
#    belongs to another user (root builds it), with umask-002 modes and a lost x bit, untracked
#    and ignored secrets, venvs and junk, and git configuration that runs programs (fsmonitor,
#    clean/smudge/process filters, textconv, hooks). It is started from a shell with an
#    activated venv whose bin/ shadows every tool, a .venv/ like it, PYTHONPATH, CONDA_PREFIX,
#    UV_*/PIP_* pointing elsewhere, GIT_DIR, BASH_ENV, CDPATH, PERL5OPT/PERL5LIB with a module of
#    its own, exported shell functions named like the build's tools (and compgen, unset). None of
#    it may run (no marker) or reach
#    the packages; the one untracked, not ignored file is named as not built.
#  * dirty: a modified, a deleted, a staged, a staged-then-deleted, a `git rm --cached` and a new
#    file: make deb warns, names each once under the right heading, says the version stays the
#    changelog's, and builds exactly that (source package only).
#  * symlink: a tracked symlink reaches the source package as that symlink.
#  * worktree-unreachable: a worktree whose repository is not there stops the build, with the
#    fix in the message, and writes nothing; the same for a .git that points elsewhere.
#  * no-git: a tree without .git (an unpacked source package) is built as it is.
#
#   bash scripts/tests/make_deb.sh [--reference <dir>]
# <dir> holds the .deb, .dsc and .tar.xz of a build of the same tree (CI: the package job's
# artifact); without it a plain clone is built here first as the reference. Needs root, git, the
# Build-Depends and PyPI (the build image, like CI's lock-gates-build job).
set -uo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
# shellcheck source=packaging/clean-env.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../packaging/clean-env.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
PKG=linuxmuster-squid
REFERENCE=
if [ "${1:-}" = --reference ]; then REFERENCE="$(cd "${2:?--reference <dir>}" && pwd)"; fi
if [ "$(id -u)" != 0 ]; then echo "make_deb.sh: run as root (in the build image)" >&2; exit 2; fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MARKER="$TMP/marker"
PASS=0; FAIL=0
ok() { echo "ok    $1"; PASS=$((PASS + 1)); }
wrong() {
    echo "WRONG $1"; FAIL=$((FAIL + 1))
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
        { grep -E '^make deb|^  [a-z]' "$2" | head -n 20; echo ...; tail -n 15 "$2"; } | sed 's/^/      /'
    fi
    if [ -e "$MARKER" ]; then sed 's/^/      MARKER: /' "$MARKER"; fi
}
g() { git -c user.name=make_deb -c user.email=make_deb@invalid -c commit.gpgsign=false \
          -c core.hooksPath=/dev/null "$@"; }
VERSION="$(dpkg-parsechangelog -l "$ROOT/debian/changelog" -S Version)"

# The repository: the tracked files of this tree, committed.
REPO="$TMP/repo"
mkdir -p "$REPO"
# listed with the guards of make deb (nothing the checkout's git config names runs)
GIT_OPTIONAL_LOCKS=0 git --no-pager -c safe.directory="$ROOT" -c core.fsmonitor=false \
    -c core.hooksPath=/dev/null -C "$ROOT" ls-files -z | (cd "$ROOT" && xargs -0 cp --parents -a -t "$REPO")
g -C "$REPO" init -q && g -C "$REPO" add -A -f && g -C "$REPO" commit -q -m fixture \
    || { echo "cannot create the fixture repository"; exit 1; }
# What the source package must hold: the tracked files without .github/, .claude/ and
# dpkg-source's default ignores (.gitignore), each with git's mode (0755 or 0644), dirs 0755.
g -C "$REPO" ls-files -s \
    | awk -F'\t' '{ split($1, m, " "); print (m[1] == "100755" ? "755" : m[1] == "120000" ? "link" : "644"), $2 }' \
    | grep -Ev ' (\.github|\.claude)/| (.*/)?\.gitignore$' | LC_ALL=C sort > "$TMP/expected"

# listing <tarball>: "<mode> <path>" of every file (644/755) and symlink (link) in it, like
# $TMP/expected; a directory that is not 0755 and an owner other than 0/0 are listed as such
listing() {
    tar -tvJf "$1" --numeric-owner | awk -v pkg="$PKG/" '
        {
            path = $6; for (i = 7; i <= NF; i++) path = path " " $i
            sub(/ -> .*/, "", path); sub(/\/$/, "", path)
            if (index(path, pkg) == 1) path = substr(path, length(pkg) + 1)
            if ($2 != "0/0") print "owner", $2, path
            if ($1 ~ /^d/) { if ($1 != "drwxr-xr-x") print "dir", $1, path; next }
            mode = $1 ~ /^l/ ? "link" : $1 == "-rwxr-xr-x" ? "755" : $1 == "-rw-r--r--" ? "644" : $1
            print mode, path
        }' | LC_ALL=C sort
}
# source_only <tree>: packaging/make-deb.sh --source there, output next to the tree
source_only() { (cd "$1" && /bin/bash packaging/make-deb.sh --source) > "$1.log" 2>&1; }

# --- traps: programs the checkout's git config or the caller's shell would run --------------
TRAPS="$TMP/traps"
mkdir -p "$TRAPS/hooks"
trap_script() { printf '#!/bin/sh\necho "%s ran: $*" >> %s\ncat\n' "$1" "$MARKER" > "$2"; chmod 0755 "$2"; }
for t in fsmonitor filter-clean filter-smudge filter-process textconv bash_env; do
    trap_script "$t" "$TRAPS/$t"
done
for h in post-index-change post-checkout pre-commit reference-transaction pre-auto-gc; do
    trap_script "hook $h" "$TRAPS/hooks/$h"
done
arm_git() {  # <repository>: the traps in its config and attributes
    local r=$1
    git -C "$r" config core.fsmonitor "$TRAPS/fsmonitor" &&
    git -C "$r" config core.hooksPath "$TRAPS/hooks" &&
    git -C "$r" config filter.trap.clean "$TRAPS/filter-clean" &&
    git -C "$r" config filter.trap.smudge "$TRAPS/filter-smudge" &&
    git -C "$r" config filter.trap.process "$TRAPS/filter-process" &&
    git -C "$r" config diff.trap.textconv "$TRAPS/textconv" &&
    mkdir -p "$(git -C "$r" rev-parse --path-format=absolute --git-common-dir)/info" &&
    echo '* filter=trap diff=trap' > "$(git -C "$r" rev-parse --path-format=absolute --git-common-dir)/info/attributes"
}
# The caller: an activated venv whose bin/ holds a marker script for every tool name a build
# could look up, whose python is real and runs a marker .pth, and settings that would send pip,
# uv and git elsewhere if the build took them.
CALLER="$TMP/caller"
/usr/bin/python3 -I -m venv --without-pip "$CALLER" || exit 1
for t in diff comm sort awk grep cut cp python3 python3.12 uv pip sed tar git mktemp env find \
         xargs wc mv rm mkdir cat head tail tr dirname basename readlink chmod touch ln sha256sum \
         make bash sh dpkg-buildpackage dpkg-source dpkg-parsechangelog dpkg-deb dh fakeroot \
         python3-config ruff mypy pytest; do
    # rm first: the venv's python3 is a symlink to the real one, and writing through it as root
    # would replace the system's interpreter
    rm -f "$CALLER/bin/$t"
    printf '#!/bin/sh\necho "%s ran instead of the real one: $*" >> %s\nexit 0\n' "$t" "$MARKER" > "$CALLER/bin/$t"
    chmod 0755 "$CALLER/bin/$t"
done
ln -sfn /usr/bin/python3 "$CALLER/bin/python"
printf 'import os; open(%s, "a").write(".pth of the caller ran\\n")\n' "'$MARKER'" \
    > "$(echo "$CALLER"/lib/python3*/site-packages)/zzz_caller.pth"
mkdir -p "$TMP/shadow/venv"
printf 'open(%s, "a").write("venv module of the caller ran\\n")\n' "'$MARKER'" \
    | tee "$TMP/shadow/venv/__init__.py" > "$TMP/shadow/venv/__main__.py"
# exported shell functions named like tools, and a CDPATH with a packaging/ of its own
mkdir -p "$TMP/cdpath/packaging"
printf 'echo "a script of the CDPATH ran" >> %s\n' "$MARKER" \
    | tee "$TMP/cdpath/packaging/clean-env.sh" > "$TMP/cdpath/packaging/make-deb.sh"
FUNCS=()
for t in awk sort git tar dpkg-buildpackage mktemp find chmod mv compgen unset; do
    FUNCS+=("BASH_FUNC_$t%%=() { echo \"function $t of the caller ran: \$*\" >> $MARKER; }")
done
# a Perl module in PERL5LIB, loaded through PERL5OPT by every dpkg and debhelper tool
mkdir -p "$TMP/perl5"
printf 'package LmnCaller; open(my $f, ">>", "%s"); print $f "perl module of the caller ran: $0\\n"; close $f; 1;\n' \
    "$MARKER" > "$TMP/perl5/LmnCaller.pm"
caller() {
    /usr/bin/env "${FUNCS[@]}" CDPATH="$TMP/cdpath" PERL5OPT=-MLmnCaller PERL5LIB="$TMP/perl5" \
        PATH="$CALLER/bin:$PATH" VIRTUAL_ENV="$CALLER" CONDA_PREFIX="$CALLER" \
        PYTHONPATH="$TMP/shadow" PYTHONHOME="$CALLER" UV_PYTHON="$CALLER/bin/python" \
        UV_DEFAULT_INDEX=http://127.0.0.1:9/simple UV_INDEX=evil=http://127.0.0.1:9/simple \
        PIP_INDEX_URL=http://127.0.0.1:9/simple PIP_REQUIRE_VIRTUALENV=1 \
        GIT_DIR=/nonexistent GIT_CONFIG_PARAMETERS="'core.fsmonitor=$TRAPS/fsmonitor'" \
        BASH_ENV="$TRAPS/bash_env" "$@"
}
# made up here, so no tracked file (this one included) can contain it
SECRET="secret-$RANDOM$RANDOM$RANDOM$RANDOM"
infest() {  # <tree>: what a developer's checkout holds besides the repository
    local d=$1
    mkdir -p "$d/deploy/secrets" "$d/deploy/e2e/ssl_db" "$d/build" "$d/.claude" "$d/.mypy_cache" \
             "$d/controlplane/lmnsquid.egg-info" "$d/controlplane/lmnsquid/__pycache__" &&
    echo "$SECRET-krb5" > "$d/deploy/secrets/krb5.conf" &&
    echo "$SECRET-keytab" > "$d/deploy/secrets/proxy.keytab" &&
    echo "$SECRET-pem" > "$d/deploy/e2e/ssl_db/key.pem" &&
    echo "TOKEN=$SECRET-env" > "$d/.env" &&
    echo "{\"token\": \"$SECRET-claude\"}" > "$d/.claude/settings.local.json" &&
    echo junk > "$d/build/junk" && echo junk > "$d/.mypy_cache/junk" &&
    echo junk > "$d/controlplane/lmnsquid.egg-info/PKG-INFO" &&
    echo junk > "$d/controlplane/lmnsquid/__pycache__/x.cpython-312.pyc" &&
    echo 'not added' > "$d/notes.txt" &&
    cp -a "$CALLER" "$d/.venv" && cp -a "$TMP/shadow/venv" "$d/venv"
}

# --- full: the hostile checkout, built for real ---------------------------------------------
if [ -z "$REFERENCE" ]; then
    echo "== reference: make deb of a plain clone"
    mkdir -p "$TMP/plain" && g clone -q "$REPO" "$TMP/plain/$PKG" &&
        (cd "$TMP/plain/$PKG" && /usr/bin/make deb) > "$TMP/plain.log" 2>&1 \
        || { wrong "reference build" "$TMP/plain.log"; exit 1; }
    REFERENCE="$TMP/plain"
fi
echo "== full: make deb of a hostile checkout, from a poisoned shell"
HOSTILE="$TMP/hostile/repo" WT="$TMP/hostile/wt/$PKG"
mkdir -p "$TMP/hostile/wt"
g clone -q "$REPO" "$HOSTILE" && g -C "$HOSTILE" worktree add -q "$WT" HEAD 2>/dev/null &&
    arm_git "$HOSTILE" && infest "$WT" &&
    chmod -R g+w "$WT" && chmod -x "$WT/scripts/blocklist-refresh.sh" &&
    chown -R 1000:1000 "$TMP/hostile" || { echo "cannot prepare the hostile checkout"; exit 1; }
rm -f "$MARKER"
(cd "$WT" && caller /usr/bin/make deb) > "$TMP/full.log" 2>&1; rc=$?
out="$TMP/hostile/wt"
same=1
for f in "${PKG}_${VERSION}_amd64.deb" "${PKG}_${VERSION}.dsc" "${PKG}_${VERSION}.tar.xz"; do
    if ! cmp -s "$out/$f" "$REFERENCE/$f"; then same=0; echo "      differs from the reference: $f"; fi
done
# (tar output goes to files first: under pipefail, `tar | grep -q` fails when grep stops early)
listing "$out/${PKG}_${VERSION}.tar.xz" > "$TMP/full.list" 2>/dev/null
tar -xOJf "$out/${PKG}_${VERSION}.tar.xz" > "$TMP/full.content" 2>/dev/null
if [ "$rc" = 0 ] && [ "$same" = 1 ] && [ ! -e "$MARKER" ] && diff -u "$TMP/expected" "$TMP/full.list" &&
    grep -q 'new, not added, NOT built: *notes.txt$' "$TMP/full.log" &&
    ! grep -q 'modified, built' "$TMP/full.log" && ! grep -aq "$SECRET" "$TMP/full.content"; then
    ok "full: .deb, .dsc and tarball of the hostile worktree = reference ($(sha256sum "$out/${PKG}_${VERSION}_amd64.deb" | cut -c1-12)), nothing of the traps or the caller ran"
else
    wrong "full: make deb exit $rc, identical=$same" "$TMP/full.log"
fi
# The worktree's own files are untouched by the build (the export happens elsewhere).
if [ -f "$WT/deploy/secrets/krb5.conf" ] && [ ! -e "$WT/debian/$PKG" ] && [ ! -e "$WT/debian/files" ]; then
    ok "full: the checkout is left as it was"
else
    wrong "full: the build changed the checkout"
fi
# Counter-proofs, after the build: the traps are armed and the ownership guard is on. Root's
# plain git refuses the checkout, and a `git status` that trusts it runs the checkout's programs.
rm -f "$MARKER"
if ! git -C "$WT" rev-parse --show-toplevel > /dev/null 2>&1 &&
    git -c safe.directory="$WT" -C "$WT" status --porcelain > /dev/null 2>&1; [ -s "$MARKER" ]; then
    ok "full counter-proof: git guards the checkout, and git status there runs its traps ($(cut -d: -f1 "$MARKER" | sort -u | tr '\n' ' '))"
else
    wrong "full counter-proof: the traps did not run in git status, or the ownership guard is off"
fi

# --- dirty: modified, deleted, staged, new ----------------------------------------------------
D="$TMP/dirty/$PKG"
mkdir -p "$TMP/dirty"
g clone -q "$REPO" "$D" &&
    echo 'LOCAL EDIT' >> "$D/README.md" && rm "$D/docs/install.md" &&
    echo 'staged' > "$D/staged.txt" && g -C "$D" add staged.txt &&
    echo 'gone' > "$D/staged-gone.txt" && g -C "$D" add staged-gone.txt && rm "$D/staged-gone.txt" &&
    g -C "$D" rm -q --cached docs/references.md &&
    echo 'print("new")' > "$D/new_module.py" && arm_git "$D" || { echo "cannot prepare dirty"; exit 1; }
rm -f "$MARKER"
source_only "$D"; rc=$?
tb="$TMP/dirty/${PKG}_${VERSION}.tar.xz"
tar -tJf "$tb" > "$TMP/dirty.list" 2>/dev/null
tar -xOJf "$tb" "$PKG/README.md" > "$TMP/dirty.readme" 2>/dev/null
if [ "$rc" = 0 ] && [ ! -e "$MARKER" ] &&
    grep -q "WARNING: .*version $VERSION" "$D.log" &&
    grep -q 'modified, built as they are now: *README.md$' "$D.log" &&
    grep -q 'deleted, left out: *docs/install.md$' "$D.log" &&
    grep -q 'staged, not committed (built): *staged.txt$' "$D.log" &&
    grep -q 'new, not added, NOT built: *new_module.py$' "$D.log" &&
    grep -q 'removed from the index, NOT built: *docs/references.md$' "$D.log" &&
    grep -q 'deleted, left out: *staged-gone.txt$' "$D.log" &&
    [ "$(grep -c 'docs/references.md$' "$D.log")" = 1 ] && ! grep -q 'built): *staged-gone.txt$' "$D.log" &&
    [ "$(tail -n 1 "$TMP/dirty.readme")" = 'LOCAL EDIT' ] && grep -qx "$PKG/staged.txt" "$TMP/dirty.list" &&
    ! grep -q -e "^$PKG/docs/install.md$" -e "^$PKG/new_module.py$" -e "^$PKG/docs/references.md$" \
        -e "^$PKG/staged-gone.txt$" "$TMP/dirty.list"; then
    ok "dirty: warned with the version, named each file once and rightly, built exactly the working tree"
else
    wrong "dirty: exit $rc" "$D.log"
fi

# --- symlink ------------------------------------------------------------------------------
D="$TMP/symlink/$PKG"
mkdir -p "$TMP/symlink"
g clone -q "$REPO" "$D" && ln -s ../README.md "$D/docs/README-link.md" && g -C "$D" add docs/README-link.md &&
    g -C "$D" commit -q -m link || { echo "cannot prepare symlink"; exit 1; }
source_only "$D"; rc=$?
tar -tvJf "$TMP/symlink/${PKG}_${VERSION}.tar.xz" > "$TMP/symlink.list" 2>/dev/null
if [ "$rc" = 0 ] && grep -q "^l.* $PKG/docs/README-link.md -> \.\./README.md$" "$TMP/symlink.list" &&
    ! grep -q WARNING "$D.log"; then
    ok "symlink: a tracked symlink is in the source package as that symlink"
else
    wrong "symlink: exit $rc" "$D.log"
fi

# --- worktree-unreachable, .git pointing elsewhere ------------------------------------------
R="$TMP/unreach/repo" D="$TMP/unreach/wt/$PKG"
mkdir -p "$TMP/unreach/wt"
g clone -q "$REPO" "$R" && g -C "$R" worktree add -q "$D" HEAD 2>/dev/null && infest "$D" &&
    mv "$R/.git" "$R/.git.away" || { echo "cannot prepare worktree-unreachable"; exit 1; }
source_only "$D"; rc=$?
if [ "$rc" != 0 ] && grep -q 'git cannot use it' "$D.log" && grep -q 'mount it there' "$D.log" &&
    [ -z "$(find "$TMP/unreach/wt" -maxdepth 1 -name "${PKG}_*" -print -quit)" ]; then
    ok "worktree-unreachable: stops (exit $rc) with the mount in the message, writes nothing"
else
    wrong "worktree-unreachable: exit $rc" "$D.log"
fi
# a .git that git can read, but whose repository names another working tree (core.worktree)
echo "gitdir: $REPO/.git" > "$D/.git" && git -C "$REPO" config core.worktree "$REPO"
source_only "$D"; rc=$?
git -C "$REPO" config --unset core.worktree
if [ "$rc" != 0 ] && grep -q 'git cannot use it for this tree' "$D.log" &&
    [ -z "$(find "$TMP/unreach/wt" -maxdepth 1 -name "${PKG}_*" -print -quit)" ]; then
    ok "a repository whose working tree is elsewhere: stops (exit $rc), writes nothing"
else
    wrong "a repository whose working tree is elsewhere: exit $rc" "$D.log"
fi

# --- no-git -------------------------------------------------------------------------------
D="$TMP/nogit/$PKG"
mkdir -p "$D" && cp -a "$REPO/." "$D" && rm -rf "$D/.git"
source_only "$D"; rc=$?
if [ "$rc" = 0 ] && grep -q 'holds no .git' "$D.log" && [ -f "$TMP/nogit/${PKG}_${VERSION}.dsc" ]; then
    ok "no-git: an unpacked source tree is built as it is"
else
    wrong "no-git: exit $rc" "$D.log"
fi

echo "make deb: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
