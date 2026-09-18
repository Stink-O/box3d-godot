#!/usr/bin/env bash
# Assemble the release assets into dist/ from binaries already built by
# build_all.sh. Three assets, the shape every GDExtension project ships:
#
#   dist/0-box3d-demo-project.zip         the whole demo project with the addon
#                                       inside; unzip, open box3d-demo/project.godot
#   dist/box3d-addon-v<ver>.zip   addons/box3d/ (manifest, LICENSE,
#                                       README, every platform binary, icons);
#                                       unzip into any project, restart Godot.
#                                       The same file goes to the Godot Asset
#                                       Store.
#   dist/box3d-demo-android.apk         the demo, debug-signed ("Android" preset)
#   dist/box3d-demo-web-threaded.zip    the demo's threaded web export, for
#                                       itch.io (butler) and self-hosting behind
#                                       real COOP/COEP headers
#
# Usage: godot/tools/package_release.sh <version> <godot 4.7 editor binary>
# The Godot binary must match the installed export templates (4.7.stable).
set -euo pipefail
VER="${1:?version, e.g. 0.4.3}"; GODOT="${2:?path to the Godot 4.7 editor binary}"
cd "$(dirname "$0")/.."
ADDON=demo/addons/box3d
# Godot resolves export paths against the PROJECT folder, so use absolute ones.
ROOT="$(cd .. && pwd)"
DIST="$ROOT/dist"
WEBFAST="$ROOT/webfast"
mkdir -p "$DIST"

# 1. Every library the manifest lists must exist; the manifest version must match.
grep -q "^version = \"$VER\"" "$ADDON/box3d.gdextension" || { echo "manifest version is not $VER"; exit 1; }
missing=0
while read -r path; do
  f="$ADDON/${path#res://addons/box3d/}"
  [ -e "$f" ] || { echo "MISSING: $f"; missing=1; }
done < <(grep -oE '^[a-z0-9_.]+ = "res://addons/box3d/[^"]+"' "$ADDON/box3d.gdextension" | sed -E 's/.*"(res:[^"]+)"/\1/')
[ "$missing" = 0 ] || exit 1
# Nothing stale may ride along: only what the manifest names, plus icons.
for f in "$ADDON"/bin/*; do
  grep -q "$(basename "$f")" "$ADDON/box3d.gdextension" || { echo "UNLISTED binary in bin/: $f (retired variant? delete it)"; exit 1; }
done

# 2. Windows DLLs are MinGW cross builds: only KERNEL32 and msvcrt may be imported.
for dll in "$ADDON"/bin/*.dll; do
  bad=$(objdump -p "$dll" | awk '/DLL Name/ {print $3}' | grep -viE '^(KERNEL32\.dll|msvcrt\.dll)$' || true)
  [ -z "$bad" ] || { echo "$dll imports $bad (static link failed)"; exit 1; }
done

# 3. The addon zip.
rm -f "$DIST/box3d-addon-v$VER.zip"
( cd demo && zip -qr "$DIST/box3d-addon-v$VER.zip" addons/box3d -x '*.import' -x '*.uid' )
unzip -l "$DIST/box3d-addon-v$VER.zip" | tail -1

# 4. The demo project zip: the tracked demo tree (git, so no .godot cache or
# export leftovers) plus the binaries, under a box3d-demo/ folder.
STAGE="$(mktemp -d)"; mkdir -p "$STAGE/box3d-demo"
git archive HEAD demo | tar -x -C "$STAGE/box3d-demo" --strip-components=1 -f -
mkdir -p "$STAGE/box3d-demo/addons/box3d/bin"; cp "$ADDON"/bin/* "$STAGE/box3d-demo/addons/box3d/bin/"
rm -f "$DIST/0-box3d-demo-project.zip"
( cd "$STAGE" && zip -qr "$DIST/0-box3d-demo-project.zip" box3d-demo ); rm -rf "$STAGE"

# 5. Demo exports. --import first (a new class_name otherwise bakes a broken
# script), then restore project.godot, which --import rewrites and strips.
"$GODOT" --headless --path demo --import > /dev/null 2>&1 || true
git checkout demo/project.godot
grep -q 'rendering_method.web="gl_compatibility"' demo/project.godot || { echo "project.godot lost the web renderer key"; exit 1; }
"$GODOT" --headless --path demo --export-debug "Android" "$DIST/box3d-demo-android.apk" 2>&1 | grep -iE 'error|savepack|done' || true
[ -s "$DIST/box3d-demo-android.apk" ] || { echo "APK export failed"; exit 1; }
rm -rf "$WEBFAST"; mkdir -p "$WEBFAST"
"$GODOT" --headless --path demo --export-release "Web Threaded" "$WEBFAST/index.html" 2>&1 | grep -iE 'error|done' || true
[ -s "$WEBFAST/index.wasm" ] || { echo "web export failed"; exit 1; }
# The kill-switch must sit at the OLD service worker URL (see its header).
cp tools/web_sw_killswitch.js "$WEBFAST/index.service.worker.js"
rm -f "$DIST/box3d-demo-web-threaded.zip"
( cd "$WEBFAST" && zip -qr "$DIST/box3d-demo-web-threaded.zip" . )

echo; echo "== dist/"; ls -la "$DIST"
echo
echo "Next: verify the web export in a browser twice (CLAUDE.md), then"
echo "  gh release create v$VER --draft -R Stink-O/box3d-godot dist/0-box3d-demo-project.zip dist/box3d-addon-v$VER.zip dist/box3d-demo-android.apk dist/box3d-demo-web-threaded.zip"
echo "  butler push webfast stinkysunstep/box3d-godot:html --userversion $VER"
