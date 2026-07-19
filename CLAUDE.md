# Agent guide — box3d-godot

Guidance for AI agents working in this repository. The deep Android
documentation is `godot/ANDROID_BUILD.md`; this file is the rules and the
expensive lessons.

## What this repo is

A fork of [erincatto/box3d](https://github.com/erincatto/box3d) plus a
**Godot 4.7 GDExtension** living in `godot/`. Desktop (Windows/Linux) and
Android are supported and verified; macOS has manifest entries but has never
been built.

## The rule that outranks everything: additive fork discipline

**Never modify upstream-owned files** — anything that exists in
`erincatto/box3d`: `src/`, `include/`, `test/`, `samples/`, `shared/`,
`extern/`, root build files and docs. Everything custom lives in `godot/`,
the top section of `README.md`, and `.gitignore`. This is what keeps
`git merge upstream/main` conflict-free.

If upstream code is wrong, file an issue upstream instead of patching the
vendored copy — [erincatto/box3d#92](https://github.com/erincatto/box3d/issues/92)
(arm32 NEON) is the model: documented locally, fixed upstream, zero divergence.

## Commit rules

- **No Claude/AI attribution.** No `Co-Authored-By`, no "generated with"
  trailers, no AI mentions in messages. Plain messages, repo user as author.
- One focused commit per logical change.
- **Never `git push` without the user explicitly saying so.** Publishing is
  their decision, every time.

## Verification ritual — run before AND after any change

```sh
GODOT=<path to Godot 4.7 editor binary>
"$GODOT" --headless --path godot/demo --import
"$GODOT" --headless --path godot/demo res://tests/test_features.tscn -- --selftest
"$GODOT" --headless --path godot/demo res://tests/test_samples.tscn  -- --selftest
```

- Expect 44 `[test]` lines and 30 `[samples]` lines, in both cases counting
  the final `[test]/[samples] ALL -> PASS` line. **Exit 0 alone is not a
  pass** — an empty enumeration once produced a vacuous `ALL -> PASS`; always
  grep the actual lines.
- Diff the output against the previous run. Mobile-only changes must leave
  desktop output **byte-identical**.
- Known quirk: the *first* `--import` on a clean tree can abort (exit 134)
  during editor teardown after the import succeeded; a second run exits 0.
  Pre-existing, not your bug.
- Shell/UI changes aren't covered by the selftests — also boot the shell:
  `"$GODOT" --headless --path godot/demo res://main.tscn --quit-after 120`
  and grep the log for `SCRIPT ERROR`.

## Building

```sh
cd godot
scons -jN                                   # Linux (desktop)
export ANDROID_HOME=~/Android/Sdk
scons platform=android arch=arm64  target=template_debug
scons platform=android arch=x86_64 target=template_release   # etc.
```

- The required NDK version is pinned in `godot/godot-cpp/tools/android.py`
  (currently `28.1.13356709`). Use that one. **Never bump the godot-cpp
  submodule pin** without explicit user approval.
- `arm32` does not compile — upstream bug (#92). Do not "fix" it by editing
  `core.h` or by disabling SIMD.
- Keep `-j` modest (leave the user most of their cores) when they're active.

## Determinism red lines

Box3D's scalar, SSE2 and NEON paths are **bit-exact** with each other — a
tested feature (upstream `test_determinism`, hash `0x1E5EDD79`), not an
accident. Therefore:

- Never remove `-ffp-contract=off`. Never add `-ffast-math`.
- `BOX3D_DISABLE_SIMD` is a diagnostic, not a fix.

## Android gotchas (each of these cost real debugging time)

- The manifest is `godot/demo/bin/box3d.gdextension` and it's a Godot
  ConfigFile: **comments are `;`, not `#`** — a `#` line silently breaks the
  entire manifest and the extension stops loading. Keys look like
  `android.debug.arm64`; the filename says `template_debug` but the key says
  `debug`. Leave `box3d.gdextension.uid` alone.
- **A new GDScript `class_name` needs `--headless --import` before the next
  export**, or the APK bakes a parse-broken script while the export still
  reports success. After any install, read device logs:
  `adb logcat -s godot:V` — never trust exit codes alone.
- Launcher activity: `org.box3d.godot.samples/com.godot.game.GodotAppLauncher`
  (not `GodotApp`).
- **Emulator Vulkan is broken** (gfxstream, llvmpipe, SwiftShader all fail at
  present and the scene never runs). For emulator work, force GL **per
  export** via the preset: `command_line/extra_args="--rendering-method
  gl_compatibility"` — never in `project.godot`. Real devices run Vulkan
  fine (verified on Mali-G57 hardware).
- `--fixed-fps` does nothing on Android (the platform drives the loop from
  vsync). Don't rely on it to speed up on-device test runs.
- Firebase Test Lab: use `godot/tools/testlab_arm64.sh`. Only physical
  devices or `*.arm` **virtual** devices exercise arm64 — default virtual
  devices are x86 and prove nothing. Robo tears the session down ~17 s in,
  so a long-running harness gets cut off; that truncation is deterministic
  and is not a code bug.
- Mobile-only settings go through `.mobile` feature tags in `project.godot`;
  mobile-only code is gated on `DisplayServer.is_touchscreen_available()`.
  Desktop must never observe mobile behavior.
- **Measure before optimizing** (protocol in `ANDROID_BUILD.md` §9: export
  with `--print-fps`, stir the physics, average logcat samples). The demo
  was draw-call bound; the standard mobile knobs (shadow size, MSAA, render
  scale) measured as no-ops here, while MultiMesh doubled FPS.

## Binaries policy

`*.so` / `*.apk` are gitignored, except the committed Windows DLLs
(`!godot/demo/bin/libbox3d_godot.windows.*.dll` — "clone and play" on
Windows). Prebuilt Android + Linux libraries ship as GitHub release assets
instead. Note: the committed Windows DLLs were built before the last
upstream core sync and are one revision stale — rebuild on a Windows machine
when possible.

## Upstream sync procedure

```sh
git fetch upstream
git merge upstream/main
# run the verification ritual above
# push only with user approval
```

Upstream's `simd_sat` branch is active work worth checking when it lands —
this port's verification leans on the NEON path.
