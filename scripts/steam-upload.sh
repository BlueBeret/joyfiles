#!/usr/bin/env bash
# uploads build/ to Steam with steamcmd, only by hand and only with real ids
set -euo pipefail

usage() {
	cat <<'EOF'
usage: STEAM_USERNAME=name scripts/steam-upload.sh

The script refuses to run when:
  a placeholder value remains in steam/*.vdf
  steamcmd is missing from the PATH
  build/linux or build/windows is missing
  stdin is not a terminal
Steam asks for the password and the Steam Guard code itself.
EOF
}

case "${1:-}" in
	"") ;;
	-h | --help) usage; exit 0 ;;
	*) usage >&2; exit 2 ;;
esac

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() {
	echo "error: $*" >&2
	exit 1
}

placeholders="$(grep -nE '^[^/]*REPLACE_ME' "$root"/steam/*.vdf || true)"
if [[ -n "$placeholders" ]]; then
	echo "$placeholders" >&2
	die "replace the REPLACE_ME values above before you upload"
fi

command -v steamcmd >/dev/null || die "steamcmd not found on the PATH"
[[ -n "${STEAM_USERNAME:-}" ]] || die "set STEAM_USERNAME"
for f in build/linux/joyfiles.x86_64 build/windows/joyfiles.exe; do
	[[ -s "$root/$f" ]] || die "$f is missing, run scripts/export.sh first"
done
[[ -t 0 ]] || die "stdin is not a terminal, this script never runs unattended"

preview="$(sed -n 's/.*"Preview"[[:space:]]*"\([01]\)".*/\1/p' "$root/steam/app_build.vdf")"
echo "app build: $root/steam/app_build.vdf (Preview=$preview)"
read -r -p 'type "upload" to continue: ' answer
[[ "$answer" == upload ]] || die "cancelled"

steamcmd +login "$STEAM_USERNAME" +run_app_build "$root/steam/app_build.vdf" +quit
