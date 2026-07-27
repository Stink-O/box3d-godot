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

One deliberate exception: `.github/workflows/godot-web-pages.yml`, because
GitHub only reads workflows from `.github/workflows/` and there is nowhere
else to put it. It is additive and its name is one upstream would never pick,
so a merge stays clean. Do not touch `.github/workflows/build.yml`, which is
upstream's.

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

- Expect 47 `[test]` lines and 33 `[samples]` lines, in both cases counting
  the final `[test]/[samples] ALL -> PASS` line. **Exit 0 alone is not a
  pass** — an empty enumeration once produced a vacuous `ALL -> PASS`; always
  grep the actual lines.
- Diff the output against the previous run. Mobile-only changes must leave
  desktop output **byte-identical**.
- Known quirk: the *first* `--import` on a clean tree can abort (exit 134)
  during editor teardown after the import succeeded; a second run exits 0.
  Pre-existing, not your bug.
- Web-affecting changes (anything in `godot/src/` or `godot/demo/`) also get
  the web ritual — see "The browser demo" below.
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

**No build output is tracked.** `*.so`, `*.dll` and `*.apk` are all
gitignored, with no exceptions. Every prebuilt binary ships as a GitHub
release asset instead, versioned against the tag that produced it.

Windows DLLs used to be committed for "clone and play", and it went exactly
how vendored binaries go: they silently fell four upstream core syncs behind
and ended up missing bindings the demo had started calling, so a fresh clone
got a degraded demo with nothing to indicate why. A release asset cannot drift
from its tag, and a download link is less work for a newcomer than a clone.

Windows DLLs can be cross-compiled from Linux, which is how they are now
produced for releases:

```sh
sudo dnf install mingw64-gcc-c++ mingw64-winpthreads-static   # Fedora
cd godot
scons platform=windows arch=x86_64 target=template_debug
scons platform=windows arch=x86_64 target=template_release
```

godot-cpp takes the MinGW branch automatically on a non-Windows host. Verify
the result imports only `KERNEL32.dll` and `msvcrt.dll` (`objdump -p`); any
`libgcc`/`libstdc++` import means the static link failed. These are a
different toolchain from MSVC and the determinism guarantee has only been
checked on scalar/SSE2/NEON, so treat a cross-built DLL as untested until
someone runs it on Windows.

## The browser demo — two builds, one deploy (each rule below cost real debugging time)

The demo is publicly playable in a browser, and it is part of the product
surface now: **any change to `godot/src/` or `godot/demo/` also changes the
web demo**, and shipping it means rebuilding BOTH web variants and running the
deploy. Do not treat web as an afterthought of a desktop change.

| | root (fallback) | `/fast/` |
|---|---|---|
| URL | stink-o.github.io/box3d-godot | box3d-fast.stinkysunstep.workers.dev |
| threads | single (nothreads template) | multi (threaded template) |
| Cube Pile | halved to 2048 at load | full 4096 |
| extension | `...wasm32.nothreads.wasm` | `...wasm32.wasm` |
| needs COOP/COEP | no | **yes, or it does not load at all** |

```sh
source ~/emsdk/emsdk_env.sh        # Emscripten 4.0.11, pinned (dlink is version-sensitive)
cd godot
scons platform=web threads=no  target=template_release
scons platform=web threads=yes target=template_release
```

Deploy = run the **"Deploy web demo to Pages"** workflow (manual dispatch, on
purpose — publishing is a decision). It exports both variants (root + `/fast/`),
plants the kill-switch service worker, verifies its own output, and fails the
build if the wrong variant would land in either slot. The Cloudflare Worker in
`godot/tools/web_fast_worker` only needs redeploying (`npx wrangler deploy`
from that directory) when the worker itself changes — it is a pass-through and
does not embed the demo.

### The hard rules

- **A threaded wasm module cannot load without real COOP/COEP headers.** It
  declares shared memory; an un-isolated page hands it non-shared memory and it
  dies with `LinkError: mismatch in shared state of memory`. This is why the
  fallback exists, why `/fast/` is served *through* the Worker (GitHub Pages
  cannot send headers), and why the threaded export's `head_include` bounces
  direct un-isolated visitors to the fallback. Never flip the root preset to
  `thread_support=true`.
- **Service workers are not an acceptable substitute for headers.** Godot's PWA
  isolation trick (and the community coi-serviceworker, same architecture)
  cannot cover a first visit or a hard refresh — both shipped broken here
  before this was learned. The only service worker that may be deployed is the
  kill-switch (`godot/tools/web_sw_killswitch.js`), which exists to *unregister*
  the one that briefly shipped; keep deploying it, it is inert for new visitors.
- **Cloudflare Pages cannot host the build**: `index.side.wasm` is 41 MiB
  against a 25 MiB per-file cap, every plan. Hence the Worker-proxy topology.
  Do not "simplify" it back to direct hosting.
- **Do not give the Worker cache hints.** `cacheTtl` caches every status, and a
  cached 404 (fetched before a deploy landed) once served the whole site as
  missing for an hour. It defers to GitHub's cache-control; bump `CACHE_BUST`
  in `wrangler.toml` if the edge cache is ever poisoned again.
- Platform behavior differences are gated on **feature tags**, never on new
  properties: `OS.has_feature("web")` (banner, `WEB_FIRST_SAMPLE`),
  `and not OS.has_feature("threads")` (Cube Pile halving). Desktop and the
  47/33 gate must never observe web behavior.
- `-msimd128 -msse2` (SConstruct) is required — box3d maps `B3_CPU_WASM` onto
  its SSE2 path. `BOX3D_NO_THREADS` is defined only for `threads=no` web builds
  and makes the wrapper clamp `worker_count` and refuse `async_step`; without
  pthreads a refused thread ABORTS (exceptions are off), it does not error.
- **Determinism on wasm is unverified** (upstream's Emscripten CI is
  build-only). Never claim the browser build is bit-exact with native.

### Web verification ritual — never trust one load

An export "succeeds" with a broken page, and a page that works on the SECOND
load can still be broken on the first (that exact combination shipped). Before
any deploy, serve the export from a plain header-less server (`python3 -m
http.server`, which is exactly what GitHub Pages is) and verify in a real
browser, minimum:

1. **First load on a FRESH browser profile** — must boot; console must show
   `Build configuration: ... single-threaded, GDExtension support` (or
   `multi-threaded` behind a COOP/COEP server for `/fast/`).
2. **Hard refresh / caches disabled** — must boot identically.
3. No `LinkError`, no `SCRIPT ERROR`, and the banner present.

The shell has flags that make this scriptable: `-- --shot=out.png
--shot-tick=N` (renders the game viewport only and quits — never capture the
desktop; the user streams), `--profiler`, `--settings`, `--sample="Name"`
(exact display name; a typo silently opens the first sample). After deploying,
run the same checks against the live URLs.

## Release checklist

Releases are the only distribution channel for binaries (nothing prebuilt is
tracked). v0.3.0 is the shape to match — 12 assets:

| asset | built by |
|---|---|
| `libbox3d_godot.linux.template_{debug,release}.x86_64.so` | `scons` / `scons target=template_release` |
| `libbox3d_godot.android.template_{debug,release}.{arm64,x86_64}.so` | `ANDROID_HOME=~/Android/Sdk scons platform=android arch=... target=...` |
| `libbox3d_godot.windows.template_{debug,release}.x86_64.dll` | `scons platform=windows arch=x86_64 target=...` (MinGW cross-compile; verify imports are ONLY `KERNEL32.dll`+`msvcrt.dll` via `objdump -p`, and label them untested-on-Windows unless someone has run them) |
| `libbox3d_godot.web.template_release.wasm32{,.nothreads}.wasm` | the two web builds above |
| `box3d-demo-android.apk` | `--export-debug "Android"` (debug-signed; no release keystore exists) |
| `box3d-demo-web.zip` | zip of the exported fallback `web/` **including the kill-switch worker** — must match what the Pages deploy serves |

Rules learned the hard way:

- **Build everything AFTER the final commit**, from the exact tree being
  tagged. Stale assets on a draft (built before an upstream sync or a binding
  landed) shipped a broken demo once already.
- `gh release` commands need `-R Stink-O/box3d-godot` or they hit upstream.
- Draft first; publishing is the user's click unless they say otherwise.
- New GDScript `class_name` ⇒ `--headless --import` before ANY export, or the
  APK/web build bakes a parse-broken script while the export reports success.
- If the fallback web build changed, refresh `box3d-demo-web.zip` on the
  release — a stale zip re-ships whatever bug the deploy just fixed.

## Upstream sync procedure

```sh
git fetch upstream
git merge upstream/main
# run the verification ritual above
# push only with user approval
```

Upstream's `simd_sat` branch is active work worth checking when it lands —
this port's verification leans on the NEON path.
