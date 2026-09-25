#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# `make deb`: dpkg-buildpackage on an export of exactly the files git tracks, as they are in the
# working tree. dpkg-source packs every file of the tree it builds, and a checkout holds more
# than the repository (secrets under deploy/, .env, venvs, caches, agent settings), so the tree
# that is built is an export: <tmp>/linuxmuster-squid with the tracked files, file modes as git
# records them (0644/0755, whatever the checkout's umask), fresh mtimes (dpkg clamps only mtimes
# newer than the changelog date; older ones of a long-lived checkout would reach the .deb). Left
# out on purpose: .github/ and .claude/ (CI and developer tooling) and dpkg-source's default
# ignore list (.gitignore and the like). The .deb, .changes, .buildinfo, .dsc and the source
# tarball land one level ABOVE the checkout.
#
#   bash packaging/make-deb.sh            the source and binary packages (`make deb`)
#   bash packaging/make-deb.sh --source   the source package only (no venv, no network)
#
# Uncommitted work is built as it is in the working tree: a modified tracked file with its
# changes, a deleted one or one removed from the index (git rm --cached) not at all, a new file
# only once `git add`ed. The package still carries the version of debian/changelog, so the build
# warns and lists every such file.
#
# A .git that git cannot use (a git worktree whose repository is not mounted into the container,
# see the Makefile) stops the build: it never falls back to packing whatever lies in the tree.
# Only a tree without any .git (an unpacked source package) is built as it is.
#
# git runs only commands that read (rev-parse, ls-files, ls-tree, hash-object --no-filters),
# with core.fsmonitor off, no pager and no optional locks, so nothing configured in the
# checkout's .git/config or attributes (fsmonitor, filters, hooks, pagers) runs, also not when
# root builds a checkout that belongs to someone else. safe.directory names exactly this tree.
set -euo pipefail
shopt -s inherit_errexit nullglob
PATH=/usr/sbin:/usr/bin:/sbin:/bin
# shellcheck source=packaging/clean-env.sh
. "$(dirname "${BASH_SOURCE[0]}")/clean-env.sh"
umask 022

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PKG=linuxmuster-squid
BUILDPACKAGE=(dpkg-buildpackage -us -uc -I -I.github -I.claude)
if [ "${1:-}" = --source ]; then
    BUILDPACKAGE+=(-S -d -nc)
elif [ "$#" != 0 ]; then
    echo "usage: make-deb.sh [--source]" >&2; exit 2
fi
export GIT_OPTIONAL_LOCKS=0
git_() {
    git --no-pager -c safe.directory="$ROOT" -c core.fsmonitor=false -c core.hooksPath=/dev/null \
        -C "$ROOT" "$@"
}
version="$(dpkg-parsechangelog -l "$ROOT/debian/changelog" -S Version)"

if [ ! -e "$ROOT/.git" ] && [ ! -L "$ROOT/.git" ]; then
    echo "make deb: $ROOT holds no .git (an unpacked source package?): building every file of" \
         "the tree as it is"
    cd "$ROOT"
    exec "${BUILDPACKAGE[@]}" -tc
fi
if ! top="$(git_ rev-parse --show-toplevel 2>&1)" || [ "$top" != "$ROOT" ]; then
    echo "make deb: $ROOT/.git exists, but git cannot use it for this tree: $top" >&2
    if [ -f "$ROOT/.git" ]; then
        echo "make deb: this is a git worktree; its repository ($(sed -n 's/^gitdir: //p' \
"$ROOT/.git")) must be reachable at that path. In a container, mount it there, read-only:" >&2
        # shellcheck disable=SC2016  # printed for the reader, not expanded
        echo '  GITDIR=$(git rev-parse --path-format=absolute --git-common-dir)' \
             '&& docker run ... -v "$GITDIR:$GITDIR:ro" ...   (the full command: Makefile)' >&2
    fi
    echo "make deb: not building (a tree git cannot read would be packed with everything in it)" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
EXPORT="$WORK/$PKG"
mkdir "$EXPORT"

# "<mode> <object> <stage>\t<path>" per index entry; what `git status` would report is worked
# out from the index, HEAD and the files themselves, without git's own worktree comparison
# (that one runs the checkout's clean filters and fsmonitor).
git_ ls-files -s -z > "$WORK/index"
if head="$(git_ rev-parse -q --verify 'HEAD^{commit}')"; then
    git_ ls-tree -r -z --full-tree HEAD > "$WORK/head"
else
    head=; : > "$WORK/head"
fi
declare -A in_head=() in_index=()
while IFS= read -r -d '' entry; do
    meta="${entry%%$'\t'*}" path="${entry#*$'\t'}"
    in_head[$path]="${meta%% *} ${meta##* }"          # "<mode> <object>"
done < "$WORK/head"
files=() regular=() modes=() deleted=() modified=() staged=() removed=() unmerged=()
while IFS= read -r -d '' entry; do
    meta="${entry%%$'\t'*}" path="${entry#*$'\t'}"
    read -r mode object stage <<< "$meta"
    if [ "$stage" != 0 ]; then unmerged+=("$path"); continue; fi
    in_index[$path]=1
    if [ ! -e "$ROOT/$path" ] && [ ! -L "$ROOT/$path" ]; then deleted+=("$path"); continue; fi
    if [ "${in_head[$path]:-}" != "$mode $object" ]; then staged+=("$path"); fi
    files+=("$path") modes+=("$mode")
    case "$mode" in
        100644 | 100755)
            if [ -L "$ROOT/$path" ] || [ ! -f "$ROOT/$path" ]; then
                echo "make deb: $path is a regular file in git, but a symlink or directory in the" \
                     "working tree; commit or undo that change first" >&2; exit 1
            fi
            regular+=("$path $object") ;;
        120000)   # a symlink: git's object is its target
            if [ ! -L "$ROOT/$path" ]; then
                echo "make deb: $path is a symlink in git, but not in the working tree; commit or" \
                     "undo that change first" >&2; exit 1
            fi
            if [ "$(printf '%s' "$(readlink "$ROOT/$path")" | git_ hash-object --no-filters --stdin)" \
                 != "$object" ]; then
                modified+=("$path")
            fi ;;
        *) echo "make deb: $path has git mode $mode (a submodule?), which a package cannot hold" >&2
           exit 1 ;;
    esac
done < "$WORK/index"
if [ "${#unmerged[@]}" != 0 ]; then
    printf 'make deb: unmerged path, resolve the conflict first: %s\n' "${unmerged[@]}" >&2; exit 1
fi
# in the commit, but no longer in the index (git rm, git rm --cached): not built
declare -A is_removed=()
for path in "${!in_head[@]}"; do
    if [ -z "${in_index[$path]:-}" ]; then removed+=("$path") is_removed[$path]=1; fi
done
# the content of every regular tracked file, hashed without any filter, against the index
if [ "${#regular[@]}" != 0 ]; then
    for r in "${regular[@]}"; do
        case "${r% *}" in *$'\n'*) echo "make deb: a tracked path holds a newline" >&2; exit 1 ;; esac
    done
    mapfile -t hashes < <(printf '%s\n' "${regular[@]% *}" | git_ hash-object --no-filters --stdin-paths)
    [ "${#hashes[@]}" = "${#regular[@]}" ] || { echo "make deb: git hash-object failed" >&2; exit 1; }
    for i in "${!regular[@]}"; do
        if [ "${hashes[$i]}" != "${regular[$i]##* }" ]; then modified+=("${regular[$i]% *}"); fi
    done
fi
untracked=()
while IFS= read -r -d '' path; do
    # a file git rm --cached took out of the index is listed once, as removed
    if [ -z "${is_removed[$path]:-}" ]; then untracked+=("$path"); fi
done < <(git_ ls-files -z --others --exclude-standard --directory --no-empty-directory)

if [ "${#modified[@]}${#deleted[@]}${#staged[@]}${#removed[@]}${#untracked[@]}" != 00000 ]; then
    {
        echo "make deb: WARNING: the working tree is not commit ${head:-(none yet)}."
        echo "make deb: WARNING: built are the tracked files AS THEY ARE IN THE WORKING TREE, and"
        echo "make deb: WARNING: the package still says version $version: it is not the package of that commit."
        list() {  # <label> <path>...
            local label=$1; shift
            if [ "$#" != 0 ]; then printf '%s\n' "$@" | LC_ALL=C sort | sed "s|^|  $label  |"; fi
        }
        list "modified, built as they are now:" "${modified[@]}"
        list "staged, not committed (built):  " "${staged[@]}"
        list "deleted, left out:              " "${deleted[@]}"
        list "removed from the index, NOT built:" "${removed[@]}"
        list "new, not added, NOT built:      " "${untracked[@]}"
    } >&2
fi

printf '%s\0' "${files[@]}" > "$WORK/files"
tar -C "$ROOT" --null --no-recursion -T "$WORK/files" -cf - \
    | tar -C "$EXPORT" --no-same-owner --no-same-permissions --touch -xf -
# the modes git records, not those of the checkout (its umask, a lost x bit)
find "$EXPORT" -type d -exec chmod 0755 {} +
for i in "${!files[@]}"; do
    case "${modes[$i]}" in
        100755) chmod 0755 "$EXPORT/${files[$i]}" ;;
        100644) chmod 0644 "$EXPORT/${files[$i]}" ;;
    esac
done
echo "make deb: building ${#files[@]} tracked files (commit ${head:-none}, version $version) in $EXPORT"

(cd "$EXPORT" && "${BUILDPACKAGE[@]}")
out=("$WORK/${PKG}_"*)
[ "${#out[@]}" != 0 ] || { echo "make deb: dpkg-buildpackage wrote nothing" >&2; exit 1; }
mv -f "${out[@]}" "$ROOT/.."
printf 'make deb: %s\n' "${out[@]##*/}"
