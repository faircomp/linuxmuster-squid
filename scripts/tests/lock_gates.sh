#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Regression test for the gate between the lock files and everything built from them
# (packaging/lock-deps.sh; packaging/build-venv.sh and the fast tier run it before anything
# from a lock is installed):
#   --lint           only the lines uv writes (offline)
#   --gate           --lint, the uv-only tool lock proven with the standard library, then with
#                    that uv: every hash one PyPI publishes for exactly that name==version, the
#                    pins exactly the closure of the declared inputs, a target wheel per pin
#   --verify-freeze  after installing: the venv is exactly the lock plus the given packages
# The lock cases start with the manipulations of the cold verifications of stage A and of the
# debian/ conversion (linuxmusterDEV work/verification/cold-stage-a.md F2,
# cold-debian-squid.md F1). Every crafted case must be rejected for the reason named with it;
# a case that passes, or fails for another reason, fails this script.
#
# The K1 cases (cold-debian-squid.md F1): a wheel that brings its own diff, comm, sort, awk,
# grep, cut, cp, python3, uv, pip and more (TOOLS below) into its venv's bin/ and a .pth that
# runs in every interpreter of that venv; each writes a marker file. It is "published": a local
# PEP 691 index serves it with its real sha256 and an upload time older than 7 days, as PyPI
# would serve a package an attacker uploaded, and sends every other name on to PyPI. Grammar and
# hash checks therefore pass and only the closure check can stop it, and it must do so before
# anything of the wheel ran: no marker, no .deb. The gate takes its index from one line of
# packaging/lock-deps.sh (PYPI_SIMPLE=, and nothing from the environment); these cases change
# that line, and only that line (checked), in their copy of the tree. Nothing a real build reads
# is touched.
#
# The caller cases (cold-debian-*-r2.md: squid F3, readonlydc F1, radius F3): the gate, `make
# deb` and `run.sh quick` started from an activated venv holding the K1 wheel (in front of PATH,
# VIRTUAL_ENV, CONDA_PREFIX, UV_PYTHON pointing at it, a PYTHONPATH with a `venv` module of its
# own) and with such a venv as .venv/ (and a `venv/` package) in the checkout: nothing of it may
# run, and a manipulated lock is still rejected. Their counter-proofs switch the protection off
# in a copy (the gate's fixed PATH and clean environment; the gate in the build) and must see a
# marker from one of the wheel's bin/ tools, so the test cannot pass on an unarmed wheel.
#
#   bash scripts/tests/lock_gates.sh          --lint and --verify-freeze cases (offline) and the
#                                             --gate cases (need PyPI and /usr/bin/python3 with
#                                             venv)
#   bash scripts/tests/lock_gates.sh --build  `make deb` in a copy of the tree per lock case: it
#                                             must stop in the lock gate, before any venv of the
#                                             build exists. Needs the Build-Depends (CI: the
#                                             build image, as root).
# LOCK_GATES_VERBOSE=1 prints the gate's own words for each rejected case.
set -uo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=packaging/clean-env.sh
. "$ROOT/packaging/clean-env.sh"
PYTHON=/usr/bin/python3
LOCK_DEPS="$ROOT/packaging/lock-deps.sh"
CP=controlplane/requirements.lock
BL=packaging/requirements-build.lock
UL=packaging/requirements-uv.lock
TMP="$(mktemp -d)"
INDEX_PID=
trap '[ -z "$INDEX_PID" ] || kill "$INDEX_PID" 2>/dev/null; rm -rf "$TMP"' EXIT
PASS=0; FAIL=0; SKIP=0
MARKER="$TMP/k1-marker"

# ok <label> <command...>: must exit 0.
# rejects <label> <reason ERE> <command...>: must exit non-zero AND print the reason, so a
# case cannot pass because something unrelated broke. Output goes to $TMP/out.
ok() {
    local label=$1 rc
    shift
    "$@" > "$TMP/out" 2>&1; rc=$?
    if [ "$rc" = 0 ]; then
        echo "ok    $label"; PASS=$((PASS + 1))
    else
        echo "WRONG $label (expected exit 0, got $rc)"; sed 's/^/      /' "$TMP/out"; FAIL=$((FAIL + 1))
    fi
}
rejects() {
    local label=$1 reason=$2 rc
    shift 2
    rm -f "$MARKER"
    "$@" > "$TMP/out" 2>&1; rc=$?
    if [ "$rc" != 0 ] && grep -Eq -- "$reason" "$TMP/out" && [ ! -e "$MARKER" ]; then
        echo "ok    $label (exit $rc)"; PASS=$((PASS + 1))
        if [ -n "${LOCK_GATES_VERBOSE:-}" ]; then grep -E -- "$reason" "$TMP/out" | head -n 3 | sed 's/^/      /'; fi
    else
        echo "WRONG $label (expected a rejection for /$reason/ and no marker, got exit $rc)"
        tail -n 30 "$TMP/out" | sed 's/^/      /'
        if [ -e "$MARKER" ]; then sed 's/^/      MARKER: /' "$MARKER"; fi
        FAIL=$((FAIL + 1))
    fi
}

# --- the K1 wheel and the index that publishes it -----------------------------------------
# Everything the gate, the build and run.sh might look up on PATH, and what a lock-filled venv
# could shadow: the gate's text tools, python3, uv, pip, the build's own programs, the fast
# tier's tools.
TOOLS=(diff comm sort awk grep cut cp python3 uv pip sed tar git mktemp env find xargs wc mv rm
       mkdir cat head tail tr dirname basename readlink chmod touch ln sha256sum make bash sh
       dpkg-buildpackage dpkg-source dpkg-parsechangelog ruff mypy pytest shellcheck reuse curl)
"$PYTHON" -I - "$TMP/wheels" "$MARKER" "${TOOLS[@]}" <<'PY'
import base64, hashlib, os, sys, zipfile

out, marker = sys.argv[1:3]
tools = sys.argv[3:]
os.makedirs(out)
files = {"zzzevil2/__init__.py": b""}
files["zzzevil2.pth"] = (
    f"import os, sys; open({marker!r}, 'a').write('.pth ran in %s (pid %d)\\n' "
    f"% (sys.executable, os.getpid()))\n"
).encode()
for t in tools:
    files[f"zzzevil2-1.0.data/scripts/{t}"] = (
        f'#!/bin/sh\necho "{t} ran instead of the real one: $*" >> {marker}\nexit 0\n'
    ).encode()
files["zzzevil2-1.0.dist-info/METADATA"] = b"Metadata-Version: 2.1\nName: zzzevil2\nVersion: 1.0\n"
files["zzzevil2-1.0.dist-info/WHEEL"] = (
    b"Wheel-Version: 1.0\nGenerator: lock_gates.sh\nRoot-Is-Purelib: true\nTag: py3-none-any\n"
)

def row(path, data):
    digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
    return f"{path},sha256={digest},{len(data)}\n"

record = "".join(row(p, d) for p, d in files.items()) + "zzzevil2-1.0.dist-info/RECORD,,\n"
files["zzzevil2-1.0.dist-info/RECORD"] = record.encode()
with zipfile.ZipFile(os.path.join(out, "zzzevil2-1.0-py3-none-any.whl"), "w") as z:
    for path, data in files.items():
        info = zipfile.ZipInfo(path, (2026, 1, 1, 0, 0, 0))
        # regular file + mode: pip sets the executable bit only for S_ISREG entries with x bits
        info.external_attr = (0o100755 if "/scripts/" in path else 0o100644) << 16
        z.writestr(info, data)
PY
WHEEL="$TMP/wheels/zzzevil2-1.0-py3-none-any.whl"
EVIL_HASH="$(sha256sum "$WHEEL" | cut -d' ' -f1)"
# poison <dir>: a venv with the K1 wheel installed (never on this script's PATH): every TOOLS
# name in its bin/ is the wheel's marker script, and its .pth runs in its interpreter. The venv's
# python pointed at python3, which is the wheel's script now; it becomes a real interpreter of
# the venv again, so the .pth has one to run in.
poison() {
    "$PYTHON" -I -m venv "$1" && "$1/bin/python" -I -m pip install --quiet --no-deps "$WHEEL" &&
        ln -sfn "$PYTHON" "$1/bin/python"
}
# The wheel is armed, or a missing marker proves nothing: installed into a throwaway venv, every
# one of its bin/ tools is executable and runs (pip installed them from *.data/scripts/), and
# its .pth runs in that venv's interpreter (python3 is the wheel's script by now, python is not).
armed() {
    local t
    poison "$TMP/armed" || return 1
    for t in "${TOOLS[@]}"; do
        if ! { [ -x "$TMP/armed/bin/$t" ] && [ ! -L "$TMP/armed/bin/$t" ] && "$TMP/armed/bin/$t" a b &&
               grep -qx "$t ran instead of the real one: a b" "$MARKER"; }; then
            echo "bin/$t is not armed"; return 1
        fi
    done
    "$TMP/armed/bin/python" -c pass && grep -q '^.pth ran in ' "$MARKER"
}
if armed; then
    echo "ok    the K1 wheel is armed: its ${#TOOLS[@]} bin/ tools and its .pth write the marker"
    PASS=$((PASS + 1))
else
    echo "WRONG the K1 wheel is not armed"; sed 's/^/      MARKER: /' "$MARKER" 2>/dev/null; FAIL=$((FAIL + 1))
fi
rm -rf "$MARKER" "$TMP/armed"
evil_block() {  # the pin as uv writes it
    printf 'zzzevil2==1.0 \\\n    --hash=sha256:%s\n    # via %s\n' "$EVIL_HASH" "$1"
}
cat > "$TMP/index.py" <<'PY'
# A PEP 691 simple index for the wheels in one directory; every other project is redirected to
# PyPI's own page, so for all else uv and pip see exactly what PyPI serves. upload-time is old
# enough for --exclude-newer=P7D.
import hashlib, http.server, json, os, sys

root, port_file = sys.argv[1:3]


class Index(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, body, ctype):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parts = [p for p in self.path.split("?")[0].split("/") if p]
        wheels = sorted(f for f in os.listdir(root) if f.endswith(".whl"))
        if len(parts) == 2 and parts[0] == "files" and parts[1] in wheels:
            return self.send(open(os.path.join(root, parts[1]), "rb").read(), "application/octet-stream")
        if len(parts) == 2 and parts[0] == "simple":
            mine = [w for w in wheels if w.split("-")[0].replace("_", "-") == parts[1]]
            if mine:
                files = [{"filename": w, "url": f"/files/{w}", "upload-time": "2026-01-01T00:00:00.000000Z",
                          "hashes": {"sha256": hashlib.sha256(open(os.path.join(root, w), "rb").read()).hexdigest()}}
                         for w in mine]
                body = {"meta": {"api-version": "1.1"}, "name": parts[1], "files": files,
                        "versions": sorted({w.split("-")[1] for w in mine})}
                return self.send(json.dumps(body).encode(), "application/vnd.pypi.simple.v1+json")
            self.send_response(302)
            self.send_header("Location", f"https://pypi.org/simple/{parts[1]}/")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(404)
        self.end_headers()


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Index)
with open(port_file + ".tmp", "w") as f:
    f.write(str(server.server_address[1]))
os.rename(port_file + ".tmp", port_file)
server.serve_forever()
PY
"$PYTHON" -I "$TMP/index.py" "$TMP/wheels" "$TMP/index.port" & INDEX_PID=$!
for _ in $(seq 1 50); do [ -s "$TMP/index.port" ] && break; sleep 0.1; done
[ -s "$TMP/index.port" ] || { echo "WRONG the local index did not start"; exit 1; }
INDEX_URL="http://127.0.0.1:$(cat "$TMP/index.port")/simple"
# publish <tree>: its gate asks the local index instead of PyPI. The one line changes, nothing
# else (a copy whose gate differs in more would test another gate).
publish() {
    local f="$1/packaging/lock-deps.sh"
    sed -i "s|^PYPI_SIMPLE=https://pypi.org/simple\$|PYPI_SIMPLE=$INDEX_URL|" "$f" &&
        [ "$(diff "$ROOT/packaging/lock-deps.sh" "$f" | grep -c '^[<>]')" = 2 ] &&
        grep -qx "PYPI_SIMPLE=$INDEX_URL" "$f"
}

# --- the lock cases -------------------------------------------------------------------------
H64="$(printf 'e%.0s' $(seq 64))"
URL_LINE="    zzzevil @ file:///evil/zzzevil-1.0-py3-none-any.whl#sha256=$H64"
# six 1.17.0 as uv writes it, with the real sha256 of its wheel and sdist on PyPI: a pin that
# pip installs and the freeze gate accepts, but that nothing in the inputs asks for.
SIX_PIN="six==1.17.0 \\
    --hash=sha256:4721f391ed90541fddacab5acf947aa0d3dc7d27b2e1e8eda2be8970586c3274 \\
    --hash=sha256:ff70335d468e7eb6ec65b95b99d3a2836546063f63acc5171de367e834932a81
    # via lmnsquid"
# The first pin with exactly two hashes (a pure-Python wheel and its sdist). pip downloads
# only the wheel, so changing the sdist's hash passes pip; both hash cases must fail anyway.
PIN="$(awk '/^[a-z0-9]/ { order[++k] = $1; next } /^    --hash=/ { n[order[k]]++ }
            END { for (i = 1; i <= k; i++) if (n[order[i]] == 2) { print order[i]; exit } }' \
            "$ROOT/$CP")"
[ -n "$PIN" ] || { echo "no pin with two hashes in $CP"; exit 1; }
# A uv release younger than 7 days, if there is one right now (for tool-lock-young-uv).
YOUNG_UV="$("$PYTHON" -I -S - <<'PY' || true
import datetime, json, urllib.request
cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=6, hours=12)
with urllib.request.urlopen("https://pypi.org/pypi/uv/json", timeout=60) as r:
    releases = json.load(r)["releases"]
young = [(max(f["upload_time_iso_8601"] for f in fs), v) for v, fs in releases.items()
         if fs and all(datetime.datetime.fromisoformat(f["upload_time_iso_8601"].replace("Z", "+00:00")) > cutoff for f in fs)]
if young:
    version = max(young)[1]
    print(f"uv=={version} \\")
    hashes = sorted(f["digests"]["sha256"] for f in releases[version])
    print(" \\\n".join(f"    --hash=sha256:{h}" for h in hashes))
    print("    # via -r packaging/requirements-uv.in")
PY
)"

# case -> the step that must stop it; its words
declare -A STOP=(
    [indented-url]=lint [extra-index-url]=lint [hashes-removed]=lint [pin-without-hash]=lint
    [build-lock-indented-url]=lint
    [hash-changed-1]=check [hash-changed-2]=check [extra-pin]=check [build-lock-extra-pin]=check
    [k1-build-lock]=check [k1-both-locks]=check
    [tool-lock-extra-pin]=tool [tool-lock-hash-changed]=tool [tool-lock-k1]=tool
    [tool-lock-young-uv]=tool
)
declare -A WHY=(
    [lint]="lines a lock never contains"
    [hash-changed-1]="hashes PyPI does not list" [hash-changed-2]="hashes PyPI does not list"
    [extra-pin]="pins no longer match the inputs" [build-lock-extra-pin]="pins no longer match the inputs"
    [k1-build-lock]="pins no longer match the inputs" [k1-both-locks]="pins no longer match the inputs"
    [tool-lock-extra-pin]="must pin uv and nothing else" [tool-lock-k1]="must pin uv and nothing else"
    [tool-lock-hash-changed]="not published by PyPI" [tool-lock-young-uv]="less than 7 days ago"
)
CASES=(indented-url extra-index-url hashes-removed hash-changed-1 hash-changed-2 extra-pin
       pin-without-hash build-lock-indented-url build-lock-extra-pin k1-build-lock k1-both-locks
       tool-lock-extra-pin tool-lock-hash-changed tool-lock-k1 tool-lock-young-uv)
why() { if [ "${STOP[$1]}" = lint ]; then echo "${WHY[lint]}"; else echo "${WHY[$1]}"; fi; }
# The K1 cases must be stopped by the closure check alone: the hash check passed ("published").
NOT_WHY="hashes PyPI does not list|index does not publish"

# flip <lock> <pin> <nth>: the last hex digit of the nth hash of <pin>, still 64 hex digits
flip() {
    awk -v pin="$2" -v nth="$3" '
        $1 == pin { inpin = 1; n = 0; print; next }
        inpin && /^    --hash=sha256:/ {
            if (++n == nth) {
                i = index($0, "sha256:") + 7 + 63; d = substr($0, i, 1)
                $0 = substr($0, 1, i - 1) (d == "0" ? "1" : "0") substr($0, i + 1)
            }
            print; next
        }
        { inpin = 0; print }' "$1" > "$1.edit" && mv "$1.edit" "$1"
}

# apply <case> <tree>: the manipulation, in a copy of the repository
apply() {
    local c=$1 d=$2
    case "$c" in
        indented-url) printf '%s\n' "$URL_LINE" >> "$d/$CP" ;;
        extra-index-url) printf '%s\n' '--extra-index-url https://evil.example/simple' >> "$d/$CP" ;;
        hashes-removed)
            awk -v pin="$PIN" '$1 == pin { print pin; drop = 1; next }
                               drop && /^    --hash=/ { next }
                               { drop = 0; print }' "$d/$CP" > "$d/edit" && mv "$d/edit" "$d/$CP" ;;
        hash-changed-1 | hash-changed-2) flip "$d/$CP" "$PIN" "${c##*-}" ;;
        extra-pin) printf '%s\n' "$SIX_PIN" >> "$d/$CP" ;;
        pin-without-hash) printf '%s\n' 'six==1.17.0' >> "$d/$CP" ;;
        build-lock-indented-url) printf '%s\n' "$URL_LINE" >> "$d/$BL" ;;
        build-lock-extra-pin) printf '%s\n' "$SIX_PIN" >> "$d/$BL" ;;
        k1-build-lock) evil_block "-r packaging/requirements-build.in" >> "$d/$BL" ;;
        k1-both-locks)
            evil_block "-r packaging/requirements-build.in" >> "$d/$BL"
            evil_block lmnsquid >> "$d/$CP" ;;
        tool-lock-extra-pin) printf '%s\n' "$SIX_PIN" >> "$d/$UL" ;;
        tool-lock-hash-changed) flip "$d/$UL" "$(awk '/^uv==/ { print $1 }' "$d/$UL")" 1 ;;
        tool-lock-k1) evil_block "-r packaging/requirements-uv.in" >> "$d/$UL" ;;
        tool-lock-young-uv) { sed -n 1,2p "$d/$UL"; printf '%s\n' "$YOUNG_UV"; } > "$d/edit" && mv "$d/edit" "$d/$UL" ;;
        *) echo "unknown case $c" >&2; return 1 ;;
    esac
    # the manipulation must have changed a lock, or the case proves nothing
    ! cmp -s "$ROOT/$CP" "$d/$CP" || ! cmp -s "$ROOT/$BL" "$d/$BL" || ! cmp -s "$ROOT/$UL" "$d/$UL"
}

# copy <dest>: the tracked files of the repository (what CI checks out)
copy() {
    mkdir -p "$1"
    git -c safe.directory="$ROOT" -c core.fsmonitor=false -C "$ROOT" ls-files -z \
        | (cd "$ROOT" && xargs -0 cp --parents -a -t "$1")
}
# commit <tree>: a git repository with everything in it committed, as a pull request brings it
# (make deb then exports exactly these files)
commit() {
    git -C "$1" init -q && git -C "$1" add -A -f &&
        git -C "$1" -c user.name=lock_gates -c user.email=lock_gates@invalid -c commit.gpgsign=false \
            -c core.hooksPath=/dev/null commit -q -m fixture
}
# The caller cases: an activated venv holding the K1 wheel, and the same as .venv/ (with a
# `venv` package next to it) in the tree the command runs in.
SHADOW="$TMP/shadow"
mkdir -p "$SHADOW/venv"
printf 'open(%s, "a").write("venv module of the caller ran\\n")\n' "'$MARKER'" \
    | tee "$SHADOW/venv/__init__.py" > "$SHADOW/venv/__main__.py"
poison "$TMP/caller" || { echo "WRONG could not create the caller's venv"; exit 1; }
infest() {  # <tree>: .venv/ and venv/ of the caller in it
    poison "$1/.venv" && cp -a "$SHADOW/venv" "$1/venv"
}
caller() {  # <command...> started from the activated venv, as a developer would
    /usr/bin/env PATH="$TMP/caller/bin:$PATH" VIRTUAL_ENV="$TMP/caller" CONDA_PREFIX="$TMP/caller" \
        UV_PYTHON="$TMP/caller/bin/python" PYTHONPATH="$SHADOW" "$@"
}
# gate_open <tree>: the counter-proof, the gate without its fixed PATH and clean environment
gate_open() {
    local f="$1/packaging/lock-deps.sh"
    sed -i -e '/^PATH=\/usr\/sbin:\/usr\/bin:\/sbin:\/bin$/d' -e '/^\. packaging\/clean-env\.sh$/d' "$f" &&
        [ "$(diff "$ROOT/packaging/lock-deps.sh" "$f" | grep -c '^[<>]')" = 2 ]
}
tool_ran() { grep -Eq '^[^ ]+ ran instead of the real one' "$MARKER" 2>/dev/null; }

# build_stops <case> <label> <dir> [caller]: `make deb` in <dir>/src must stop in the lock gate:
# its words in the log, no build venv, no shipped venv, no .deb, nothing of the K1 wheel ran.
build_stops() {
    local c=$1 label=$2 d=$3 rc
    shift 3
    rm -f "$MARKER"
    (cd "$d/src" && "$@" /usr/bin/make deb) > "$d/log" 2>&1; rc=$?
    if [ "$rc" != 0 ] && grep -Eq -- "$(why "$c")" "$d/log" && grep -q '^== lock gate ==' "$d/log" \
        && ! grep -q '^== build venv' "$d/log" && ! grep -q '^== venv @' "$d/log" \
        && [ -z "$(find "$d" -maxdepth 1 -name '*.deb' -print -quit)" ] && [ ! -e "$MARKER" ] \
        && { [[ $c != k1-* ]] || ! grep -Eq -- "$NOT_WHY" "$d/log"; }; then
        echo "ok    build $label: make deb exit $rc, stopped by the gate (${STOP[$c]}), no .deb, no marker"
        PASS=$((PASS + 1))
        if [ -n "${LOCK_GATES_VERBOSE:-}" ]; then grep -E -- "$(why "$c")|:[0-9]+: " "$d/log" | head -n 3 | sed 's/^/      /'; fi
    else
        echo "WRONG build $label: make deb exit $rc (want: non-zero, /$(why "$c")/ in the log, stopped in the gate, no .deb, no marker)"
        tail -n 30 "$d/log" | sed 's/^/      /'
        if [ -e "$MARKER" ]; then sed 's/^/      MARKER: /' "$MARKER"; fi
        FAIL=$((FAIL + 1))
    fi
}

if [ "${1:-}" = --build ]; then
    for c in "${CASES[@]}"; do
        if [ "$c" = tool-lock-young-uv ] && [ -z "$YOUNG_UV" ]; then
            echo "SKIP  build $c: no uv release younger than 7 days right now"; SKIP=$((SKIP + 1)); continue
        fi
        d="$TMP/build-$c"
        if ! { copy "$d/src" && apply "$c" "$d/src" && { [[ $c != k1-* ]] || publish "$d/src"; } &&
               commit "$d/src"; }; then
            echo "WRONG build $c: could not prepare"; FAIL=$((FAIL + 1)); continue
        fi
        build_stops "$c" "$c" "$d"
    done
    # From a developer's shell: an activated venv and a .venv/ with the K1 wheel, the K1 wheel
    # in the build lock. Nothing of either may run, and the gate still stops the build.
    c=k1-build-lock d="$TMP/build-caller"
    if copy "$d/src" && apply "$c" "$d/src" && publish "$d/src" && commit "$d/src" && infest "$d/src"; then
        build_stops "$c" "from a poisoned caller: $c" "$d" caller
    else
        echo "WRONG build from a poisoned caller: could not prepare"; FAIL=$((FAIL + 1))
    fi
    # Counter-proof: the same lock with the gate switched off in the build (pip pointed at the
    # local index in its place) installs the wheel into the build venv, and the next call of that
    # venv's pip runs the wheel's bin/pip: a marker from a bin/ tool, not only from the .pth.
    d="$TMP/build-open"
    if copy "$d/src" && apply "$c" "$d/src" && publish "$d/src" &&
        sed -i "s|^bash \"\$LOCK_DEPS\" --gate\$|export PIP_EXTRA_INDEX_URL=$INDEX_URL|" \
            "$d/src/packaging/build-venv.sh" &&
        [ "$(diff "$ROOT/packaging/build-venv.sh" "$d/src/packaging/build-venv.sh" | grep -c '^[<>]')" = 2 ] &&
        commit "$d/src"; then
        rm -f "$MARKER"
        (cd "$d/src" && /usr/bin/make deb) > "$d/log" 2>&1; rc=$?
        if tool_ran && [ -z "$(find "$d" -maxdepth 1 -name '*.deb' -print -quit)" ]; then
            echo "ok    build counter-proof: without the gate the wheel's bin/ runs in the build (make deb exit $rc):"
            PASS=$((PASS + 1))
            grep -E '^[^ ]+ ran instead of the real one' "$MARKER" | sort -u | head -n 3 | sed 's/^/      MARKER: /'
        else
            echo "WRONG build counter-proof: no marker from a bin/ tool of the wheel without the gate (exit $rc)"
            tail -n 30 "$d/log" | sed 's/^/      /'; sed 's/^/      MARKER: /' "$MARKER" 2>/dev/null
            FAIL=$((FAIL + 1))
        fi
    else
        echo "WRONG build counter-proof: could not prepare"; FAIL=$((FAIL + 1))
    fi
    echo "lock gates (build): $PASS passed, $FAIL failed, $SKIP skipped"
    [ "$FAIL" = 0 ]
    exit
fi

# --- --lint (offline) ---------------------------------------------------------------------
ok "lint: the committed lock files" bash "$LOCK_DEPS" --lint
for c in "${CASES[@]}"; do
    [ "$c" != tool-lock-young-uv ] || [ -n "$YOUNG_UV" ] || continue
    d="$TMP/lint-$c"
    if ! { copy "$d" && apply "$c" "$d"; }; then
        echo "WRONG lint $c: could not prepare"; FAIL=$((FAIL + 1)); continue
    fi
    if [ "${STOP[$c]}" = lint ]; then
        rejects "lint: $c" "${WHY[lint]}" bash "$d/packaging/lock-deps.sh" --lint
    else
        # grammatically a lock uv could have written: only --gate can tell (below)
        ok "lint: $c is well-formed, left to --gate" bash "$d/packaging/lock-deps.sh" --lint
    fi
done
for line in "evil==1.0 --hash=sha256:$H64" "-r /tmp/evil.txt" "--find-links /tmp/evil" \
            "-e /tmp/evil" "Evil==1.0 \\" "    --hash=sha256:$H64"; do
    d="$TMP/lint-extra"; rm -rf "$d"; copy "$d"; printf '%s\n' "$line" >> "$d/$CP"
    rejects "lint: '$line'" "${WHY[lint]}" bash "$d/packaging/lock-deps.sh" --lint
done

# --- --verify-freeze (offline) ------------------------------------------------------------
# What `pip freeze --all` prints for a correct build: the lock's pins in pip's spelling of
# the names, plus lmnsquid.
awk '/^[a-z0-9]/ { print $1 }' "$ROOT/$CP" \
    | sed -e 's/^pyyaml==/PyYAML==/' -e 's/^typing-extensions==/typing_extensions==/' > "$TMP/freeze.good"
echo "lmnsquid==7.3.5" >> "$TMP/freeze.good"
vf() { bash "$LOCK_DEPS" --verify-freeze "$ROOT/$CP" lmnsquid==7.3.5 < "$1"; }
ok "verify-freeze: the lock plus lmnsquid, pip's spelling" vf "$TMP/freeze.good"
freeze_case() {  # <label> <reason> <file>
    rejects "verify-freeze: $1" "$2" vf "$3"
}
{ cat "$TMP/freeze.good"; echo "zzzevil @ file:///evil/zzzevil-1.0-py3-none-any.whl"; } > "$TMP/f1"
freeze_case "a direct-URL install (the cold verification's line, installed)" "not a name==version pin" "$TMP/f1"
{ cat "$TMP/freeze.good"; echo "-e /tmp/evil"; } > "$TMP/f2"
freeze_case "an editable install" "not a name==version pin" "$TMP/f2"
{ cat "$TMP/freeze.good"; echo "zzzevil==1.0"; } > "$TMP/f3"
freeze_case "an extra plain pin" "not exactly" "$TMP/f3"
grep -v '^typer==' "$TMP/freeze.good" > "$TMP/f4"
freeze_case "a locked package missing" "not exactly" "$TMP/f4"
sed 's/^typer==.*/typer==0.1.0/' "$TMP/freeze.good" > "$TMP/f5"
freeze_case "a locked package in another version" "not exactly" "$TMP/f5"
grep -v '^lmnsquid==' "$TMP/freeze.good" > "$TMP/f6"
freeze_case "lmnsquid missing" "not exactly" "$TMP/f6"
sed 's/^lmnsquid==.*/lmnsquid==0.0.1/' "$TMP/freeze.good" > "$TMP/f7"
freeze_case "lmnsquid in another version" "not exactly" "$TMP/f7"
: > "$TMP/f8"
freeze_case "an empty venv" "not a name==version pin" "$TMP/f8"
rejects "verify-freeze: an unreadable lock" "cannot read" \
    bash "$LOCK_DEPS" --verify-freeze "$TMP/no-such.lock" lmnsquid==7.3.5 < "$TMP/freeze.good"
# the build venv: the build lock plus ensurepip's pip, nothing else
{ awk '/^[a-z0-9]/ { print $1 }' "$ROOT/$BL"; echo "pip==24.0"; } > "$TMP/fb"
# shellcheck disable=SC2016  # expanded by the inner bash
ok "verify-freeze: build venv = build lock + pip" \
    bash -c 'bash "$1" --verify-freeze "$2" pip==24.0 < "$3"' _ "$LOCK_DEPS" "$ROOT/$BL" "$TMP/fb"
{ cat "$TMP/fb"; echo "zzzevil2==1.0"; } > "$TMP/fb2"
# shellcheck disable=SC2016  # expanded by the inner bash
rejects "verify-freeze: build venv with an extra package" "not exactly" \
    bash -c 'bash "$1" --verify-freeze "$2" pip==24.0 < "$3"' _ "$LOCK_DEPS" "$ROOT/$BL" "$TMP/fb2"

# --- --gate (PyPI) --------------------------------------------------------------------------
ok "gate: the committed lock files" bash "$LOCK_DEPS" --gate
# The simulation works: through the local index, the uv of the (just proven) tool lock finds
# zzzevil2 1.0 with its sha256, within the 7-day cutoff, and a gate asking that index passes the
# committed locks (everything else comes from PyPI).
"$PYTHON" -I -m venv "$TMP/uvtool" && "$TMP/uvtool/bin/python" -I -m pip install --quiet \
    --require-hashes --no-deps --only-binary :all: -r "$ROOT/$UL"
printf 'zzzevil2==1.0\n' > "$TMP/pins.in"
# shellcheck disable=SC2016  # expanded by the inner bash
ok "the local index publishes zzzevil2 with its sha256" bash -c '
    cd "$1" && UV_DEFAULT_INDEX="$4" UV_CACHE_DIR="$1/uv-cache" "$2" pip compile --quiet --no-deps \
        --generate-hashes --python-version=3.12 --exclude-newer=P7D pins.in -o published.txt &&
    grep -q "sha256:$3" published.txt' _ "$TMP" "$TMP/uvtool/bin/uv" "$EVIL_HASH" "$INDEX_URL"
d="$TMP/gate-published"
if copy "$d" && publish "$d"; then
    ok "gate: the committed lock files, asking the local index" bash "$d/packaging/lock-deps.sh" --gate
else
    echo "WRONG gate: could not point a copy at the local index"; FAIL=$((FAIL + 1))
fi
for c in "${CASES[@]}"; do
    if [ "$c" = tool-lock-young-uv ] && [ -z "$YOUNG_UV" ]; then
        echo "SKIP  gate: $c: no uv release younger than 7 days right now"; SKIP=$((SKIP + 1)); continue
    fi
    d="$TMP/gate-$c"
    if ! { copy "$d" && apply "$c" "$d" && { [[ $c != k1-* ]] || publish "$d"; }; }; then
        echo "WRONG gate $c: could not prepare"; FAIL=$((FAIL + 1)); continue
    fi
    rejects "gate: $c" "$(why "$c")" bash "$d/packaging/lock-deps.sh" --gate
    if [[ $c == k1-* ]] && grep -Eq -- "$NOT_WHY" "$TMP/out"; then
        echo "WRONG gate: $c was not published after all (the hash check rejected it)"; FAIL=$((FAIL + 1))
    fi
done

# --- the caller's environment (PyPI) --------------------------------------------------------
# From a developer's shell with the K1 wheel in the activated venv and in .venv/: the gate
# rejects a lock with a real extra package (six, published on PyPI, needed by nothing) for the
# closure, and passes the committed locks, and nothing of the caller's venvs runs either way.
d="$TMP/caller-extra-pin"
if copy "$d" && apply extra-pin "$d" && infest "$d"; then
    # shellcheck disable=SC2016  # expanded by the inner bash
    rejects "gate from a poisoned caller: extra-pin" "${WHY[extra-pin]}" \
        caller /bin/bash -c 'cd "$1" && exec /bin/bash packaging/lock-deps.sh --gate' _ "$d"
else
    echo "WRONG gate from a poisoned caller: could not prepare"; FAIL=$((FAIL + 1))
fi
d="$TMP/caller-clean"
if copy "$d" && infest "$d"; then
    rm -f "$MARKER"
    # shellcheck disable=SC2016  # expanded by the inner bash
    caller /bin/bash -c 'cd "$1" && exec /bin/bash packaging/lock-deps.sh --gate' _ "$d" > "$TMP/out" 2>&1; rc=$?
    if [ "$rc" = 0 ] && [ ! -e "$MARKER" ]; then
        echo "ok    gate from a poisoned caller: the committed locks pass, nothing of the caller ran"
        PASS=$((PASS + 1))
    else
        echo "WRONG gate from a poisoned caller on the committed locks: exit $rc"
        tail -n 20 "$TMP/out" | sed 's/^/      /'; sed 's/^/      MARKER: /' "$MARKER" 2>/dev/null
        FAIL=$((FAIL + 1))
    fi
else
    echo "WRONG gate from a poisoned caller (committed locks): could not prepare"; FAIL=$((FAIL + 1))
fi
# Counter-proof: the gate without its fixed PATH and clean environment runs the wheel's tools.
d="$TMP/caller-open"
if copy "$d" && apply extra-pin "$d" && infest "$d" && gate_open "$d"; then
    rm -f "$MARKER"
    # shellcheck disable=SC2016  # expanded by the inner bash
    caller /bin/bash -c 'cd "$1" && exec /bin/bash packaging/lock-deps.sh --gate' _ "$d" > "$TMP/out" 2>&1; rc=$?
    if tool_ran; then
        echo "ok    gate counter-proof: without its fixed PATH the caller's bin/ tools run (gate exit $rc):"
        PASS=$((PASS + 1))
        grep -E '^[^ ]+ ran instead of the real one' "$MARKER" | cut -d: -f1 | sort -u | head -n 5 | sed 's/^/      MARKER: /'
    else
        echo "WRONG gate counter-proof: no marker from a bin/ tool of the caller's venv (exit $rc)"
        tail -n 20 "$TMP/out" | sed 's/^/      /'; FAIL=$((FAIL + 1))
    fi
else
    echo "WRONG gate counter-proof: could not prepare"; FAIL=$((FAIL + 1))
fi
# The local fast tier: run.sh quick puts .venv/bin on PATH for ruff, mypy and pytest, but only
# after the gate passed. With a manipulated lock it stops at the gate and nothing else runs.
# (Its lock_gates.sh is a stub here: this script must not start itself again.)
d="$TMP/caller-run"
if copy "$d" && apply extra-pin "$d" && infest "$d" &&
    printf '#!/bin/sh\necho "lock_gates.sh started again"; exit 1\n' > "$d/scripts/tests/lock_gates.sh"; then
    rejects "run.sh quick from a poisoned caller: extra-pin" "no further step runs" \
        caller /bin/bash "$d/scripts/tests/run.sh" quick
    if ! grep -q "${WHY[extra-pin]}" "$TMP/out"; then
        echo "WRONG run.sh quick: not stopped for the closure"; FAIL=$((FAIL + 1))
    fi
else
    echo "WRONG run.sh quick from a poisoned caller: could not prepare"; FAIL=$((FAIL + 1))
fi

echo "lock gates: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" = 0 ]
