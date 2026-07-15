#!/usr/bin/env bash
# Run the Box3D binding selftest on REAL arm64 hardware via Firebase Test Lab.
#
# Why this exists: no arm64 emulator can run on an x86_64 host (Google's
# emulator refuses outright), so the shipped arm64 .so cannot be executed
# locally. Test Lab rents real phones. See godot/ANDROID_BUILD.md.
#
# IMPORTANT: only --device model=<PHYSICAL> proves anything here. Test Lab's
# *virtual* devices are x86 and would exercise the x86_64 .so we already test
# locally -- they would not touch the arm64 library at all.
#
# The APK's main scene is res://tests/test_features.tscn, so the app runs the
# 42 binding assertions on launch, prints "[test] ... -> PASS" to logcat and
# quits. We drive it with a Robo test purely as a launcher and read the logcat.
# Robo may report the run as "failed" because the app exits on its own within
# seconds -- that is expected and irrelevant. The logcat is the result.
#
# Prerequisites (one time):
#   ~/google-cloud-sdk/bin/gcloud auth login
#   ~/google-cloud-sdk/bin/gcloud config set project <your-project-id>
#   Enable Test Lab: https://console.firebase.google.com -> add project
#
# Usage:
#   ./godot/tools/testlab_arm64.sh                 # auto-pick an arm64 device
#   ./godot/tools/testlab_arm64.sh oriole 33       # explicit model + API level
#
#   # Visual run: point it at the demo instead of the harness. Test Lab records
#   # video + screenshots of every run, so this shows the samples actually
#   # rendering on a real phone under Vulkan -- something no emulator here can
#   # show. Video links are printed at the end of the gcloud output.
#   APK=godot/demo/bin/box3d_demo.apk ./godot/tools/testlab_arm64.sh

set -uo pipefail

GCLOUD="${GCLOUD:-$HOME/google-cloud-sdk/bin/gcloud}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APK="${APK:-$REPO/godot/demo/bin/box3d_testlab.apk}"
OUT="${TMPDIR:-/tmp}/box3d_testlab"

command -v "$GCLOUD" >/dev/null 2>&1 || { echo "gcloud not found at $GCLOUD"; exit 1; }
[ -f "$APK" ] || { echo "APK missing: $APK
Build it with:
  cd godot/demo
  sed -i 's|run/main_scene=\"res://main.tscn\"|run/main_scene=\"res://tests/test_features.tscn\"|' project.godot
  godot --headless --path . --export-debug \"Android\" bin/box3d_testlab.apk
  git checkout project.godot        # <-- do not forget this"; exit 1; }

if ! "$GCLOUD" auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q .; then
    echo "Not authenticated. Run:  $GCLOUD auth login"; exit 1
fi
PROJECT="$("$GCLOUD" config get-value project 2>/dev/null)"
[ -n "$PROJECT" ] && [ "$PROJECT" != "(unset)" ] || { echo "No project set. Run:  $GCLOUD config set project <id>"; exit 1; }
echo "project: $PROJECT"

MODEL="${1:-}"; VERSION="${2:-}"
if [ -z "$MODEL" ]; then
    echo "Finding a physical arm64 device..."
    # form=PHYSICAL is the whole point -- virtual devices are x86.
    read -r MODEL VERSION < <("$GCLOUD" firebase test android models list \
        --filter="form=PHYSICAL" --format="value(id, supportedVersionIds[-1])" 2>/dev/null | head -1)
    [ -n "$MODEL" ] || { echo "No physical devices available. List them with:
  $GCLOUD firebase test android models list --filter=\"form=PHYSICAL\""; exit 1; }
fi
echo "device: model=$MODEL version=$VERSION (physical)"

STAMP="run-$(date +%s)"
echo "== running on real hardware; this takes a few minutes =="
"$GCLOUD" firebase test android run \
    --type robo \
    --app "$APK" \
    --device "model=$MODEL,version=$VERSION,locale=en,orientation=portrait" \
    --timeout 120s \
    --results-dir "$STAMP" 2>&1 | tee "$OUT.run.log"

BUCKET="$(grep -oE 'gs://[^ ]*' "$OUT.run.log" | head -1)"
[ -n "$BUCKET" ] || { echo "Could not find results bucket; inspect $OUT.run.log"; exit 1; }

echo "== fetching logcat from $BUCKET =="
rm -rf "$OUT.results"; mkdir -p "$OUT.results"
"$GCLOUD" storage cp -r "$BUCKET**/logcat" "$OUT.results/" 2>/dev/null \
  || "$GCLOUD" storage cp -r "${BUCKET}" "$OUT.results/" 2>/dev/null
LOG="$(find "$OUT.results" -name "logcat*" -type f | head -1)"
[ -n "$LOG" ] || { echo "No logcat retrieved. Browse: $BUCKET"; exit 1; }

echo
echo "=================== RESULT (real arm64) ==================="
grep -E "Godot Engine|Vulkan|OpenGL API|\[test\]" "$LOG" | sed 's/.*godot *: //' | head -50
echo "==========================================================="
echo "Video + screenshots of the run are in: $BUCKET"
echo "(also linked from the console URL printed by gcloud above)"

PASS="$(grep -c '\[test\].*-> PASS' "$LOG")"
FAIL="$(grep -c '\[test\].*-> FAIL' "$LOG")"

if [ "$PASS" -eq 0 ] && [ "$FAIL" -eq 0 ]; then
    # Demo APK (no harness) -- nothing to assert; the video is the deliverable.
    echo "No [test] lines: this looks like the demo APK, not the harness."
    echo "Watch the video for whether it renders and simulates."
    grep -iE "dlopen|GDExtension|Can't open|UnsatisfiedLink|FATAL" "$LOG" | head -10 \
      || echo "No GDExtension load errors in logcat -- the extension loaded."
    exit 0
fi

echo "PASS=$PASS  FAIL=$FAIL"
if grep -q '\[test\] ALL -> PASS' "$LOG"; then
    echo "ARM64 VERIFIED: the extension loaded and physics simulated on real hardware."
    exit 0
fi
echo "NOT verified. Check for dlopen/GDExtension errors:"
grep -iE "dlopen|GDExtension|Can't open|UnsatisfiedLink|FATAL" "$LOG" | head -10
echo "Full logcat: $LOG"
exit 1
