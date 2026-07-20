#!/usr/bin/env bash
#
# Launch the physics-engine comparison harness with a chosen engine + scenario.
#
#   tools/compare.sh <engine> <scenario> [extra godot args...]
#
#   engine    box3d | godot | jolt
#   scenario  pyramid | pile | stir | chain
#
# The native servers (godot / jolt) are selected by the project setting
# physics/3d/physics_engine, which Godot reads ONCE at startup. There is no
# command-line switch for it, so this script writes a throwaway override.cfg
# next to project.godot, runs, and always removes it again (trap on EXIT) so the
# normal demo is never left altered. box3d ignores that setting entirely — it
# runs its own GDExtension world — so for box3d no override is written.
#
# Examples:
#   tools/compare.sh box3d pyramid
#   tools/compare.sh jolt  pile
#   tools/compare.sh godot stir
#   # headless timing / CI:
#   tools/compare.sh jolt pyramid --headless --quit-after 600 --fixed-fps 60
#
# Set GODOT to your Godot 4.7 binary, or rely on the default below.

set -euo pipefail

ENGINE="${1:-box3d}"
SCENARIO="${2:-pyramid}"
shift 2 2>/dev/null || shift $# 2>/dev/null || true

GODOT="${GODOT:-/home/Stinkysunstep/Downloads/Godot_v4.7-stable_linux.x86_64}"

# demo/ is one level up from this script's tools/ directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/demo"
OVERRIDE="$DEMO_DIR/override.cfg"

case "$ENGINE" in
	box3d|godot|jolt) ;;
	*) echo "engine must be one of: box3d godot jolt (got '$ENGINE')" >&2; exit 2 ;;
esac
case "$SCENARIO" in
	pyramid|pile|stir|chain) ;;
	*) echo "scenario must be one of: pyramid pile stir chain (got '$SCENARIO')" >&2; exit 2 ;;
esac

if [[ ! -x "$GODOT" ]]; then
	echo "Godot binary not found or not executable: $GODOT" >&2
	echo "Set GODOT=/path/to/Godot_v4.7-stable_linux.x86_64" >&2
	exit 2
fi

# Always clean up the override so the normal demo (main.tscn) is unaffected.
cleanup() { rm -f "$OVERRIDE"; }
trap cleanup EXIT

# Pick the native PhysicsServer3D via override.cfg (comments in a Godot
# ConfigFile are ';', never '#'). box3d needs none.
case "$ENGINE" in
	godot)
		printf '[physics]\n\n3d/physics_engine="GodotPhysics"\n' > "$OVERRIDE" ;;
	jolt)
		printf '[physics]\n\n3d/physics_engine="Jolt Physics"\n' > "$OVERRIDE" ;;
	box3d)
		rm -f "$OVERRIDE" ;;
esac

echo "compare: engine=$ENGINE scenario=$SCENARIO" >&2

"$GODOT" --path "$DEMO_DIR" res://compare/compare.tscn "$@" \
	-- --engine="$ENGINE" --scenario="$SCENARIO"
