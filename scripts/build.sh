#!/usr/bin/env bash
# builds the Rust core and copies the libraries into app/bin/
set -euo pipefail

usage() {
	cat <<'EOF'
usage: scripts/build.sh [--release] [--only linux|windows]

Without --only, the script builds Linux and builds Windows when the
x86_64-pc-windows-gnu rust target and x86_64-w64-mingw32-gcc exist.
With --only, the named target is required and a missing tool is an error.

environment:
  JF_JOBS   cargo job count (default 2)
EOF
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
win_target=x86_64-pc-windows-gnu
win_linker=x86_64-w64-mingw32-gcc
jobs="${JF_JOBS:-2}"
profile=debug
only=""

while (($#)); do
	case "$1" in
		--release) profile=release ;;
		--only)
			shift
			only="${1:-}"
			case "$only" in linux | windows) ;; *) echo "error: --only needs linux or windows" >&2; exit 2 ;; esac
			;;
		-h | --help) usage; exit 0 ;;
		*) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
	shift
done

cargo_args=(build -j "$jobs")
if [[ "$profile" == release ]]; then
	cargo_args+=(--release)
fi

target_dir="${CARGO_TARGET_DIR:-$root/core/target}"
bin_dir="$root/app/bin"
mkdir -p "$bin_dir"

install_lib() {
	local src="$1" name="$2"
	[[ -s "$src" ]] || { echo "error: build did not produce $src" >&2; exit 1; }
	cp "$src" "$bin_dir/.$name.tmp"
	mv -f "$bin_dir/.$name.tmp" "$bin_dir/$name"
	echo "installed app/bin/$name ($profile)"
}

build_linux() {
	(cd "$root/core" && nice -n 19 cargo "${cargo_args[@]}")
	install_lib "$target_dir/$profile/libjoyfiles_core.so" libjoyfiles_core.so
}

windows_missing() {
	if ! command -v "$win_linker" >/dev/null; then
		echo "$win_linker not found, install mingw-w64 (Fedora: mingw64-gcc, Debian: gcc-mingw-w64-x86-64)"
	elif [[ ! -d "$(rustc --print target-libdir --target "$win_target")" ]]; then
		echo "rust target $win_target not installed, run: rustup target add $win_target"
	fi
}

build_windows() {
	(cd "$root/core" && nice -n 19 cargo "${cargo_args[@]}" --target "$win_target")
	install_lib "$target_dir/$win_target/$profile/joyfiles_core.dll" joyfiles_core.dll
}

if [[ "$only" != windows ]]; then
	build_linux
fi

if [[ "$only" != linux ]]; then
	missing="$(windows_missing)"
	if [[ -z "$missing" ]]; then
		build_windows
	elif [[ "$only" == windows ]]; then
		echo "error: $missing" >&2
		exit 1
	else
		echo "skip windows: $missing"
	fi
fi
