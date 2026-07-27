#!/usr/bin/env bash
#
# Launch the physics-engine comparison harness.
#
#   tools/compare.sh <engine> [sample] [extra godot args...]
#
#   engine  box3d | godot | jolt
#   sample  a sample name, e.g. pyramid, ball_pit, wrecking (default: pyramid)
#
# Only the ENGINE needs a relaunch. Godot reads physics/3d/physics_engine once
# at startup and there is no runtime switch and no command-line flag for it, so
# selecting a native server means writing a throwaway override.cfg next to
# project.godot before launch. Samples are switched inside the app.
#
# The override is removed three ways, because a stale one silently changes the
# normal demo:
#   1. compare.gd deletes it in _ready(), by which point Godot has already read
#      it. This is the one that survives a crash or a kill -9.
#   2. the EXIT trap below.
#   3. a sweep on the next launch, before anything else runs.
# override.cfg is also gitignored so a survivor cannot be committed.
#
# Examples:
#   tools/compare.sh box3d pyramid
#   tools/compare.sh jolt  wrecking
#   tools/compare.sh godot ball_pit --resolution 1920x1080
#
# Set GODOT to your Godot 4.7 binary, or rely on the default below.

set -euo pipefail

ENGINE="${1:-box3d}"
SAMPLE="${2:-pyramid}"
if [[ $# -ge 2 ]]; then shift 2; elif [[ $# -eq 1 ]]; then shift 1; fi

GODOT="${GODOT:-/home/Stinkysunstep/Downloads/Godot_v4.7-stable_linux.x86_64}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/demo"
OVERRIDE="$DEMO_DIR/override.cfg"

case "$ENGINE" in
	box3d|godot|jolt) ;;
	*) echo "engine must be one of: box3d godot jolt (got '$ENGINE')" >&2; exit 2 ;;
esac

if [[ ! -f "$DEMO_DIR/samples/$SAMPLE.tscn" ]]; then
	echo "no such sample: $SAMPLE" >&2
	echo "available:" >&2
	( cd "$DEMO_DIR/samples" && ls *.tscn | sed 's/\.tscn$//' | column -c 76 ) >&2
	exit 2
fi

if [[ ! -x "$GODOT" ]]; then
	echo "Godot binary not found or not executable: $GODOT" >&2
	echo "Set GODOT=/path/to/Godot_v4.7-stable_linux.x86_64" >&2
	exit 2
fi

# Sweep a survivor from a previous crashed run before we decide what to write.
rm -f "$OVERRIDE"
cleanup() { rm -f "$OVERRIDE"; }
trap cleanup EXIT

# Godot ConfigFile: comments are ';', never '#'. A '#' line silently breaks the
# whole file. box3d ignores this setting entirely (it runs its own world), but
# it still gets Dummy so the native server is not also stepping an empty space
# and charging us for it in the frame budget.
#
# The exact strings matter and are easy to get wrong. An unregistered name is
# NOT an error: Godot falls back to DEFAULT silently, with nothing on stderr.
# The previous version of this script wrote "GodotPhysics", which is not a
# registered server, and worked only because DEFAULT resolves to GodotPhysics3D
# anyway. Verified registered values in 4.7: DEFAULT, GodotPhysics3D,
# "Jolt Physics", Dummy. Because a typo here is undetectable from the setting
# alone, compare.gd does not trust it: it identifies the live server
# behaviourally and refuses to run on a mismatch.
case "$ENGINE" in
	godot) printf '[physics]\n\n3d/physics_engine="GodotPhysics3D"\n' > "$OVERRIDE" ;;
	jolt)  printf '[physics]\n\n3d/physics_engine="Jolt Physics"\n'   > "$OVERRIDE" ;;
	box3d) printf '[physics]\n\n3d/physics_engine="Dummy"\n'          > "$OVERRIDE" ;;
esac

echo "compare: engine=$ENGINE sample=$SAMPLE" >&2

"$GODOT" --path "$DEMO_DIR" res://compare/compare.tscn "$@" \
	-- --engine="$ENGINE" --sample="$SAMPLE"
