#!/usr/bin/env bash
# starts an exported build headless and checks that the extension library loads
set -euo pipefail

usage() {
	cat <<'EOF'
usage: scripts/check-export.sh [linux|windows]

Starts the exported binary headless for a few frames. The check passes when
the binary exits with code 0, the extension library loads, and the log has no
script or library errors. The windows target runs the exe under wine.

environment:
  JF_WINEPREFIX   wine prefix (default ~/.cache/joyfiles/wineprefix)
EOF
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="${1:-linux}"
frames=60
limit=180

case "$target" in
	linux | windows) ;;
	-h | --help) usage; exit 0 ;;
	*) echo "error: unknown target: $target" >&2; usage >&2; exit 2 ;;
esac

log=""
cleanup() {
	if [[ -n "$log" ]]; then
		rm -f -- "${log:?}"
	fi
}
trap cleanup EXIT
log="$(mktemp)"

fail() {
	echo "FAIL: $*" >&2
	grep -vE '^[[:space:]]+[0-9]+:' "$log" | tail -n 40 >&2 || true
	exit 1
}

if [[ "$target" == linux ]]; then
	exe="$root/build/linux/joyfiles.x86_64"
	loaded='libjoyfiles_core\.so.*dynamically loaded'
	[[ -x "$exe" ]] || fail "$exe is missing, run scripts/export.sh linux"
	rc=0
	LD_DEBUG=files nice -n 19 timeout "$limit" "$exe" --headless --quit-after "$frames" >"$log" 2>&1 || rc=$?
else
	exe="$root/build/windows/joyfiles.exe"
	loaded='Loaded L"[^"]*joyfiles_core\.dll"'
	[[ -f "$exe" ]] || fail "$exe is missing, run scripts/export.sh windows"
	command -v wine >/dev/null || fail "wine not found on the PATH"
	rc=0
	WINEPREFIX="${JF_WINEPREFIX:-${XDG_CACHE_HOME:-$HOME/.cache}/joyfiles/wineprefix}" \
		WINEARCH=win64 WINEDLLOVERRIDES="mscoree,mshtml=" WINEDEBUG="err+all,+loaddll" \
		nice -n 19 timeout "$limit" wine "$exe" --headless --quit-after "$frames" >"$log" 2>&1 || rc=$?
fi

((rc == 0)) || fail "exit code $rc"
grep -qE "$loaded" "$log" || fail "the log does not show that the extension library loaded"
if grep -E "SCRIPT ERROR|Parse Error|Can't open dynamic library|Could not load|GDExtension.*(error|failed)" "$log" >&2; then
	fail "the log has script or library errors"
fi
echo "PASS: $target export started and loaded the extension library"
