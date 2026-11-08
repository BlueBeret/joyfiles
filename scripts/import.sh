#!/usr/bin/env bash
# imports the Godot project so later godot runs start from a warm cache
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
godot_bin="${GODOT:-godot}"

# the first run on a cold cache can crash godot at exit, the second run must pass
nice -n 19 "$godot_bin" --headless --path "$root/app" --import || echo "note: the first import exited with code $?, running it again"
nice -n 19 "$godot_bin" --headless --path "$root/app" --import
