#!/usr/bin/env bash
# Build every shipped extension binary from a clean tree, one target at a time.
#
# scons shares object files between platforms (src/*.os has no platform in its
# name) and the .sconsign.dblite happily calls a stale target current, so every
# target here starts from a swept tree. Slow, but the result is certainly the
# tagged tree. See CLAUDE.md "Building" for the history.
#
# Usage: godot/tools/build_all.sh [logdir] [jobs]
# Needs: scons, mingw64 (Windows), ANDROID_HOME (Android), ~/emsdk (web).
set -euo pipefail
cd "$(dirname "$0")/.."
LOGDIR="${1:-build_logs}"; JOBS="${2:-8}"
mkdir -p "$LOGDIR"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"

sweep() { find . -name '*.os' -delete; find . -name '*.o' -delete; rm -f .sconsign.dblite; }

build() {  # build <label> <scons args...>
  local label="$1"; shift
  sweep
  echo "== $label: scons $*"
  if scons -j"$JOBS" "$@" > "$LOGDIR/$label.log" 2>&1; then echo "   ok"; else echo "   FAILED, see $LOGDIR/$label.log"; exit 1; fi
}

build linux_debug     target=template_debug
build linux_release   target=template_release
build windows_debug   platform=windows arch=x86_64 target=template_debug
build windows_release platform=windows arch=x86_64 target=template_release
build android_arm64_debug     platform=android arch=arm64  target=template_debug
build android_arm64_release   platform=android arch=arm64  target=template_release
build android_x86_64_debug    platform=android arch=x86_64 target=template_debug
build android_x86_64_release  platform=android arch=x86_64 target=template_release
# Web last: it poisons the shared object namespace for a following desktop
# build, and nothing desktop is built after it here.
# shellcheck disable=SC1090
source "$HOME/emsdk/emsdk_env.sh" > /dev/null 2>&1
build web_threaded_release platform=web threads=yes target=template_release
# The tree is left swept so the next desktop build starts clean too.
sweep
echo "== all targets built"
ls -la demo/addons/box3d/bin/
