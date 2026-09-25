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
# grep, cut, cp, python3 and uv into its venv's bin/ and a .pth that runs in every interpreter
# of that venv; each writes a marker file. It is "published": a local PEP 691 index serves it
# with its real sha256 and an upload time older than 7 days, as PyPI would serve a package an
# attacker uploaded. Grammar and hash checks therefore pass and only the closure check can
# stop it, and it must do so before anything of the wheel ran: no marker, no .deb.
# The index is added through UV_INDEX and PIP_EXTRA_INDEX_URL, uv's and pip's own settings,
# only in the environment of this script's subprocesses. Nothing in the build or the workflows
# reads or sets a variable of its own for this; an environment that sets these in a real build
# belongs to someone who controls that build already.
#
#   bash scripts/tests/lock_gates.sh          --lint and --verify-freeze cases (offline) and the
#                                             --gate cases (need PyPI and python3 -m venv)
#   bash scripts/tests/lock_gates.sh --build  `make deb` in a copy of the tree per lock case: it
#                                             must stop in the lock gate, before any venv of the
#                                             build exists. Needs the Build-Depends (CI: the
#                                             build image, as root).
# LOCK_GATES_VERBOSE=1 prints the gate's own words for each rejected case.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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
python3 - "$TMP/wheels" "$MARKER" <<'PY'
import base64, hashlib, os, sys, zipfile

out, marker = sys.argv[1:3]
os.makedirs(out)
tools = ["diff", "comm", "sort", "awk", "grep", "cut", "cp", "python3", "uv"]
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
EVIL_HASH="$(sha256sum "$TMP/wheels/zzzevil2-1.0-py3-none-any.whl" | cut -d' ' -f1)"
# The wheel is armed, or a missing marker proves nothing: installed into a throwaway venv (never
# on PATH), its bin/diff is executable and runs, and its .pth runs in an interpreter that reads
# that site-packages (the venv's own python3 is the wheel's script by now).
armed() {
    python3 -m venv "$TMP/armed" && "$TMP/armed/bin/python" -I -m pip install --quiet \
        --disable-pip-version-check --no-deps "$TMP/wheels/zzzevil2-1.0-py3-none-any.whl" &&
    [ -x "$TMP/armed/bin/diff" ] && [ -x "$TMP/armed/bin/python3" ] && "$TMP/armed/bin/diff" a b &&
    python3 -I -c 'import site, sys; site.addsitedir(sys.argv[1])' \
        "$(echo "$TMP"/armed/lib/python3*/site-packages)" &&
    grep -q '^diff ran instead of the real one: a b$' "$MARKER" && grep -q '^.pth ran in ' "$MARKER"
}
if armed; then
    echo "ok    the K1 wheel is armed: its bin/diff and its .pth write the marker"; PASS=$((PASS + 1))
else
    echo "WRONG the K1 wheel is not armed"; sed 's/^/      MARKER: /' "$MARKER" 2>/dev/null; FAIL=$((FAIL + 1))
fi
rm -rf "$MARKER" "$TMP/armed"
evil_block() {  # the pin as uv writes it
    printf 'zzzevil2==1.0 \\\n    --hash=sha256:%s\n    # via %s\n' "$EVIL_HASH" "$1"
}
cat > "$TMP/index.py" <<'PY'
# A PEP 691 simple index for the wheels in one directory: 404 for every other project, so
# uv and pip take everything else from PyPI. upload-time is old enough for --exclude-newer=P7D.
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
        self.send_response(404)
        self.end_headers()


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Index)
with open(port_file + ".tmp", "w") as f:
    f.write(str(server.server_address[1]))
os.rename(port_file + ".tmp", port_file)
server.serve_forever()
PY
python3 "$TMP/index.py" "$TMP/wheels" "$TMP/index.port" & INDEX_PID=$!
for _ in $(seq 1 50); do [ -s "$TMP/index.port" ] && break; sleep 0.1; done
[ -s "$TMP/index.port" ] || { echo "WRONG the local index did not start"; exit 1; }
INDEX_URL="http://127.0.0.1:$(cat "$TMP/index.port")/simple"
published() {  # <command...> with zzzevil2 "on PyPI"
    UV_INDEX="published=$INDEX_URL" PIP_EXTRA_INDEX_URL="$INDEX_URL" "$@"
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
YOUNG_UV="$(python3 -I -S - <<'PY' || true
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
    git -c safe.directory='*' -C "$ROOT" ls-files -z | (cd "$ROOT" && xargs -0 cp --parents -a -t "$1")
}

if [ "${1:-}" = --build ]; then
    # The gate words must appear in the build log, no case may get past the gate (no build venv,
    # no shipped venv), leave a .deb or run anything of the K1 wheel.
    for c in "${CASES[@]}"; do
        if [ "$c" = tool-lock-young-uv ] && [ -z "$YOUNG_UV" ]; then
            echo "SKIP  build $c: no uv release younger than 7 days right now"; SKIP=$((SKIP + 1)); continue
        fi
        d="$TMP/build-$c"
        if ! { copy "$d/src" && apply "$c" "$d/src"; }; then
            echo "WRONG build $c: could not prepare"; FAIL=$((FAIL + 1)); continue
        fi
        rm -f "$MARKER"
        (cd "$d/src" && published make deb) > "$d/log" 2>&1; rc=$?
        if [ "$rc" != 0 ] && grep -Eq -- "$(why "$c")" "$d/log" && grep -q '^== lock gate ==' "$d/log" \
            && ! grep -q '^== build venv' "$d/log" && ! grep -q '^== venv @' "$d/log" \
            && [ -z "$(find "$d" -maxdepth 1 -name '*.deb' -print -quit)" ] && [ ! -e "$MARKER" ] \
            && { [[ $c != k1-* ]] || ! grep -Eq -- "$NOT_WHY" "$d/log"; }; then
            echo "ok    build $c: make deb exit $rc, stopped by the gate (${STOP[$c]}), no .deb, no marker"
            PASS=$((PASS + 1))
            if [ -n "${LOCK_GATES_VERBOSE:-}" ]; then grep -E -- "$(why "$c")|:[0-9]+: " "$d/log" | head -n 3 | sed 's/^/      /'; fi
        else
            echo "WRONG build $c: make deb exit $rc (want: non-zero, /$(why "$c")/ in the log, stopped in the gate, no .deb, no marker)"
            tail -n 30 "$d/log" | sed 's/^/      /'
            if [ -e "$MARKER" ]; then sed 's/^/      MARKER: /' "$MARKER"; fi
            FAIL=$((FAIL + 1))
        fi
    done
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
# zzzevil2 1.0 with its sha256, within the 7-day cutoff.
python3 -m venv "$TMP/uvtool" && "$TMP/uvtool/bin/python" -I -m pip install --quiet \
    --disable-pip-version-check --require-hashes --no-deps --only-binary :all: -r "$ROOT/$UL"
printf 'zzzevil2==1.0\n' > "$TMP/pins.in"
# shellcheck disable=SC2016  # expanded by the inner bash
ok "the local index publishes zzzevil2 with its sha256" published bash -c '
    cd "$1" && "$2" pip compile --quiet --no-config --no-deps --generate-hashes \
        --python-version=3.12 --exclude-newer=P7D pins.in -o published.txt &&
    grep -q "sha256:$3" published.txt' _ "$TMP" "$TMP/uvtool/bin/uv" "$EVIL_HASH"
for c in "${CASES[@]}"; do
    if [ "$c" = tool-lock-young-uv ] && [ -z "$YOUNG_UV" ]; then
        echo "SKIP  gate: $c: no uv release younger than 7 days right now"; SKIP=$((SKIP + 1)); continue
    fi
    d="$TMP/gate-$c"
    if ! { copy "$d" && apply "$c" "$d"; }; then
        echo "WRONG gate $c: could not prepare"; FAIL=$((FAIL + 1)); continue
    fi
    rejects "gate: $c" "$(why "$c")" published bash "$d/packaging/lock-deps.sh" --gate
    if [[ $c == k1-* ]] && grep -Eq -- "$NOT_WHY" "$TMP/out"; then
        echo "WRONG gate: $c was not published after all (the hash check rejected it)"; FAIL=$((FAIL + 1))
    fi
done

echo "lock gates: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" = 0 ]
