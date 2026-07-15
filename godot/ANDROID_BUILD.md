# Building the Box3D GDExtension for Android

This document explains how to build, package, and verify the Box3D GDExtension
on Android, and — more importantly — *why* each step is what it is. It is
written to be read start to finish by someone who has never seen this repo.

Everything marked **verified** below was actually executed and observed. The
"What is tested and what is not" section at the end is the honest accounting;
read it before making any claim about this port.

---

## 1. Background: what a GDExtension actually is

### At the binary level

A GDExtension is **a plain native shared library** — `.so` on Linux/Android,
`.dll` on Windows, a `.framework` on macOS. It is not bytecode, not a plugin
format, not sandboxed. Godot `dlopen()`s it and calls one exported C function.

That single fact drives this entire port. A shared library is compiled for one
CPU architecture and one C ABI. It is not portable across them. So:

- Godot's own **export templates are prebuilt** by the Godot project and ship
  inside the engine distribution. They already contain `libgodot_android.so`
  for every Android ABI.
- **Your extension is not in those templates.** Godot has never seen your code.
  You must compile your own `.so` for *each ABI you intend to run on*, and the
  export process copies them into the APK next to Godot's.

An Android APK carries native code under `lib/<abi>/`. At install time the
package manager picks the directory matching the device and extracts (or
maps) only that one. So an APK supporting arm64 and x86_64 contains two
complete copies of your library. There is no "fat binary" that adapts at
runtime, and no JIT fallback — if the `.so` for the device's ABI is missing,
the class simply does not exist at runtime.

### Why a missing/incorrect entry fails *silently*

This is the single most dangerous property of GDExtension and the reason this
document exists. When Godot cannot find or load your library:

- The classes it would have registered are **simply absent**.
- Scenes referencing them load with those nodes **missing or replaced**.
- You often get **no fatal error** — just "class not found" style breakage, or
  nothing at all.

A build that compiles, packages, installs, and launches proves *nothing* about
whether the extension loaded. That is why verification here is done by running
the actual physics test harness on the device and reading its assertions, not
by observing that the app started.

### `entry_symbol = "box3d_library_init"`

The manifest (`demo/bin/box3d.gdextension`) names one symbol:

```ini
entry_symbol = "box3d_library_init"
```

After `dlopen()`, Godot does `dlsym(handle, "box3d_library_init")` and calls
it. That function is the *entire* handshake between engine and extension. It
lives in `src/register_types.cpp`:

```cpp
extern "C" {
GDExtensionBool GDE_EXPORT box3d_library_init(
        GDExtensionInterfaceGetProcAddress p_get_proc_address,
        const GDExtensionClassLibraryPtr p_library,
        GDExtensionInitialization *r_initialization) {
    godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
    init_obj.register_initializer(initialize_box3d_module);
    init_obj.register_terminator(uninitialize_box3d_module);
    init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
    return init_obj.init();
}
}
```

Three details worth being able to defend:

- **`extern "C"`** — no C++ name mangling, so the symbol is literally
  `box3d_library_init` in the dynamic symbol table. Without it, `dlsym` fails.
- **`GDE_EXPORT`** — expands to visibility/export attributes so the symbol is
  *exported*, not hidden by `-fvisibility=hidden`.
- **`p_get_proc_address`** — Godot does not link against your library and you
  do not link against Godot. The engine hands you **one function pointer**, and
  godot-cpp calls it to look up every other engine function by name. This is
  why GDExtension survives engine updates: the boundary is a runtime-negotiated
  function table, not a link-time contract. `compatibility_minimum = "4.7"` is
  your assertion about which table layout you require.

You can confirm the symbol survived the build:

```sh
llvm-readelf --dyn-syms demo/bin/libbox3d_godot.android.template_debug.arm64.so | grep box3d_library_init
#   77: 0000000000096120    96 FUNC    GLOBAL DEFAULT   12 box3d_library_init
```

`GLOBAL` and `DEFAULT` are what matter. `LOCAL` or `HIDDEN` would mean
`dlsym` returns null and the extension silently does not load.

### How the C++ classes become Godot nodes, and who owns what

`initialize_box3d_module` runs at `MODULE_INITIALIZATION_LEVEL_SCENE` and calls
`GDREGISTER_CLASS(Box3DWorld)`, `GDREGISTER_CLASS(Box3DBody)`, and so on. That
registers each class with Godot's **ClassDB** — the same registry engine-native
classes use. From that moment `Box3DBody` is a real node type: it appears in
the editor, `.tscn` files can instantiate it, and GDScript can call its methods.

Memory ownership across the boundary, which is the part people get wrong:

- **Godot owns the node objects.** A `Box3DBody` is a `Node3D` subclass; the
  scene tree creates and frees it. Your C++ destructor runs when Godot decides.
- **Box3D owns the simulation objects.** The C core allocates its own worlds,
  bodies, and shapes in its own arenas. The wrapper holds opaque handles
  (`b3BodyId` etc.), not pointers into Godot memory.
- **The wrapper's job is to keep those two lifetimes in sync** — create the
  Box3D body when the node enters the tree, destroy it when the node leaves,
  and copy transforms across each physics step.
- Mapping a Box3D event back to a node goes `b3Shape_GetBody` →
  `b3Body_GetUserData`, where the user-data pointer is the owning node. This
  is why nothing may free a node while the world still holds a handle to it.

What crosses the boundary at runtime is therefore small and flat: handles,
POD structs (vectors, transforms), and the engine function table. No C++
objects, no exceptions (godot-cpp compiles with exceptions disabled), and no
allocator sharing.

### How the C core and the C++ wrapper meet

This project compiles **two languages into one library**:

- `src/*.cpp` (this directory) — the C++ wrapper, built as C++17.
- `../src/*.c` (repo root) — the Box3D C core, built as C17.

`SConstruct` globs both into a single `SharedLibrary`. They meet at link time,
and the wrapper includes Box3D's headers, which are C. Two flags make that
work, and neither is optional:

**`-std=gnu17`** (`SConstruct`, non-MSVC branch). godot-cpp configures a C++
standard but says nothing about C. Without this the NDK's clang compiles the
Box3D core as its default C dialect, and Box3D genuinely uses C17 features.
`gnu17` rather than `c17` because the core also uses GNU extensions.

**`-ffp-contract=off`**. This forbids the compiler from contracting `a*b+c`
into a single fused multiply-add. FMA keeps more intermediate precision, which
sounds good and is actively harmful here: Box3D is a **deterministic** solver,
and its scalar and SIMD paths must produce *bit-identical* results. Box3D's own
NEON code says so out loud — `contact_solver.c` implements `b3MulAddW` as
`vaddq_f32(a, vmulq_f32(b, c))` with the comment *"Cannot use real FMA because
it doesn't match the non-SIMD path"*. If the compiler is free to re-fuse that
back into an FMA, the SIMD and scalar paths diverge and determinism is gone.

**This matters more on ARM than on x86.** AArch64 has cheap, plentiful FMA
instructions and clang contracts aggressively by default. Removing
`-ffp-contract=off` to "fix" an Android build would silently break the property
the library exists to provide, and it would not fail any test loudly.

### Symbol visibility / `B3_API`

`include/box3d/base.h` defines `B3_API` as an export attribute **only** when
`box3d_EXPORTS` / `BOX3D_DLL` are defined. This build defines neither, so
`B3_API` is empty and the core's symbols are statically embedded into
`libbox3d_godot.*.so` rather than re-exported. That is correct and intentional:
consumers talk to the wrapper, not to Box3D's C API. Relevant only if you ever
chase a symbol-visibility problem.

---

## 2. Toolchain

### Versions — and why these exact ones

**Do not use "the newest NDK".** Use the one godot-cpp pins. Read it from
`godot-cpp/tools/android.py` at the commit you have checked out:

```python
opts.Add("android_api_level", "Target Android API level", "24")
opts.Add("ndk_version", "Fully qualified version of ndk to use for compilation.", "28.1.13356709")
```

At the pinned godot-cpp commit `ba0edfe`, that is:

| Component | Version | Why |
|---|---|---|
| **NDK** | **28.1.13356709** (r28b) | godot-cpp's own default. Matching it means the toolchain layout and flags godot-cpp assumes are the ones present. |
| **Min API level** | **24** | godot-cpp's default; it *force-clamps* anything lower and warns. |
| Godot | 4.7.stable | `compatibility_minimum = "4.7"`. Export templates **must** match the editor build exactly. |
| SDK platform | android-35 | Any recent platform works; only build-tools/aapt come from it. |
| build-tools | 35.0.0 | Godot warns "Could not find version of build tools that matches Target SDK, using 35.0.0" — harmless. |

godot-cpp resolves the NDK as **`$ANDROID_HOME/ndk/$ndk_version`**, and only
falls back to `$ANDROID_NDK_ROOT` if `ANDROID_HOME` is unset:

```python
def get_android_ndk_root(env):
    if env["ANDROID_HOME"]:
        return env["ANDROID_HOME"] + "/ndk/" + env["ndk_version"]
    else:
        return os.environ.get("ANDROID_NDK_ROOT")
```

Set `ANDROID_HOME` and let it derive the path — that is the codepath godot-cpp
actually exercises.

### Installing from scratch (Linux, no sudo required)

```sh
# 1. SDK command-line tools
cd /tmp
curl -O https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
mkdir -p ~/Android/Sdk/cmdline-tools
unzip -q commandlinetools-linux-11076708_latest.zip
mv cmdline-tools ~/Android/Sdk/cmdline-tools/latest

export ANDROID_HOME=$HOME/Android/Sdk
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"

# 2. Licenses, then the exact NDK godot-cpp wants
yes | sdkmanager --licenses
sdkmanager --install "ndk;28.1.13356709" "platform-tools" "platforms;android-35" "build-tools;35.0.0"

# 3. Export templates -- MUST match the editor version exactly
curl -L -O https://github.com/godotengine/godot/releases/download/4.7-stable/Godot_v4.7-stable_export_templates.tpz
unzip -q Godot_v4.7-stable_export_templates.tpz          # -> templates/
mkdir -p ~/.local/share/godot/export_templates/4.7.stable
cp templates/* ~/.local/share/godot/export_templates/4.7.stable/

# 4. Debug keystore, at the path Godot's editor settings expect
mkdir -p ~/.local/share/godot/keystores
keytool -genkeypair -v -keystore ~/.local/share/godot/keystores/debug.keystore \
        -storepass android -alias androiddebugkey -keypass android \
        -keyalg RSA -keysize 2048 -validity 10000 \
        -dname "CN=Android Debug,O=Android,C=US"
```

**Verify the templates version file says `4.7.stable`** (`cat templates/version.txt`)
and that it matches your editor binary. A mismatch here produces confusing
export failures unrelated to your extension.

### Godot editor settings

Godot's Android export reads three editor settings
(`~/.config/godot/editor_settings-4.7.tres`):

```ini
export/android/android_sdk_path = "/home/<user>/Android/Sdk"
export/android/java_sdk_path = "/usr/lib/jvm/java-25-openjdk"
export/android/debug_keystore = "/home/<user>/.local/share/godot/keystores/debug.keystore"
export/android/debug_keystore_pass = "android"
```

`debug_keystore_user` is unset and defaults to `androiddebugkey` — which is why
the `keytool` command above uses exactly that alias and the password `android`.

**A JRE is sufficient; a full JDK is not required.** This build works with
`java` + `keytool` only (no `javac`), because we use the **prebuilt** export
templates rather than a Gradle custom build. Verified against OpenJDK 25.
If you enable `gradle_build/use_gradle_build`, that changes — Gradle needs a
real JDK and is far pickier about the version.

### Confirm SCons found the NDK and did not fall back to the host compiler

This is worth doing once, because a silent host-compiler fallback would produce
an x86-64 `.so` with an Android filename that fails at runtime for reasons that
look nothing like the cause. The check is one command:

```sh
llvm-readelf -h demo/bin/libbox3d_godot.android.template_debug.arm64.so | grep Machine
#   Machine:  AArch64        <- if this says X86-64, the NDK was not used
```

`godot-cpp/tools/android.py` also hard-fails if the toolchain directory is
absent, so a missing NDK is loud rather than silent:

```
ERROR: Could not find NDK toolchain at <path>.
```

---

## 3. Building

```sh
cd godot
export ANDROID_HOME=$HOME/Android/Sdk

scons platform=android arch=arm64  target=template_debug   -j$(nproc)
scons platform=android arch=arm64  target=template_release -j$(nproc)
scons platform=android arch=x86_64 target=template_debug   -j$(nproc)
scons platform=android arch=x86_64 target=template_release -j$(nproc)
```

Valid `arch` values are exactly `arm64`, `x86_64`, `arm32`, `x86_32`
(`android.py` exits on anything else). See §6 for why `arm32` is not built.

`-j$(nproc)` will saturate every core. Use a smaller `-j` (and `nice`) if you
need the machine for anything else while building.

### Output filenames — derived, not guessed

The name comes from godot-cpp's `env["suffix"]`, built in
`godot-cpp/tools/godotcpp.py:518-529`:

```python
suffix = ".{}.{}".format(env["platform"], env["target"])   # .android.template_debug
# (.dev / .double inserted here if those options are set)
suffix += "." + env["arch"]                                # .arm64
```

`android.py` sets `env["SHLIBSUFFIX"] = ".so"`, and `SConstruct` composes
`{bindir}/{libname}{suffix}{SHLIBSUFFIX}`. Android takes the generic `else`
branch (only macOS/iOS are special-cased), giving:

```
demo/bin/libbox3d_godot.android.template_debug.arm64.so
demo/bin/libbox3d_godot.android.template_release.arm64.so
demo/bin/libbox3d_godot.android.template_debug.x86_64.so
demo/bin/libbox3d_godot.android.template_release.x86_64.so
```

Note the library is `libbox3d_godot`, **not** `libbox3d`.

### What `android.py` passes to clang

For `arch=arm64`, from `arch_info_table`:

```
--target=aarch64-linux-android24   -march=armv8-a   -fPIC
-D ANDROID_ENABLED -D UNIX_ENABLED
lto: forced to "none" on Android
```

The `24` suffix on the target triple *is* the min API level — that is how the
NDK selects which bionic symbols exist.

---

## 4. The manifest (`demo/bin/box3d.gdextension`)

This is the one change Android absolutely requires, and a wrong key here is the
classic silent failure.

```ini
android.debug.arm64 = "res://bin/libbox3d_godot.android.template_debug.arm64.so"
android.release.arm64 = "res://bin/libbox3d_godot.android.template_release.arm64.so"
android.debug.x86_64 = "res://bin/libbox3d_godot.android.template_debug.x86_64.so"
android.release.x86_64 = "res://bin/libbox3d_godot.android.template_release.x86_64.so"
```

Things that are easy to get wrong:

- **The key says `debug`/`release`; the filename says `template_debug`/
  `template_release`.** They are not the same word, and both appear on the same
  line. This mismatch is entirely normal and constantly mistyped.
- The key is `<platform>.<target>.<arch>` and the arch names are Godot's
  (`arm64`, `x86_64`, `arm32`, `x86_32`) — **not** Android's ABI names
  (`arm64-v8a`, `armeabi-v7a`, `x86`). The ABI directory inside the APK uses
  Android's names; the manifest uses Godot's. Both appear in this project.
- These key names were not guessed. They are copied from godot-cpp's own
  `test/project/example.gdextension` **at the pinned commit** — the
  authoritative source for what this exact godot-cpp expects.

**`.gdextension` is a Godot ConfigFile: comments start with `;`, not `#`.**
A `#` comment is parsed as an identifier and breaks the whole file:

```
ERROR: ConfigFile parse error at res://bin/box3d.gdextension:18: Unexpected identifier 'arm32'.
ERROR: Error loading extension: 'res://bin/box3d.gdextension'.
```

(Hit during this port. See §7.)

Leave `box3d.gdextension.uid` alone — it is Godot's stable resource identity
for the manifest; regenerating it churns every `.tscn` that references the
extension's classes.

---

## 5. Exporting

`demo/export_presets.cfg` defines an `Android` preset. The parts that matter:

```ini
architectures/arm64-v8a=true
architectures/x86_64=true
architectures/armeabi-v7a=false
architectures/x86=false
gradle_build/use_gradle_build=false      # use the prebuilt templates
package/unique_name="org.box3d.godot.samples"
```

```sh
cd godot/demo
export ANDROID_HOME=$HOME/Android/Sdk
godot --headless --path . --export-debug "Android" bin/box3d_demo.apk
```

`--export-debug` selects the `template_debug` libraries; `--export-release`
selects `template_release`. The APK is **not** committed (`.gitignore`) — it is
~60 MB and fully regenerable.

### `project.godot` needed one change

Godot's Android export gate refuses to run without ETC2/ASTC:

```
ERROR: ETC2/ASTC texture compression is required for Android export.
```

So `project.godot` gains:

```ini
textures/vram_compression/import_etc2_astc=true
```

**This demo ships zero textures** — every mesh is procedural — so this
compresses nothing, changes no imported asset, and has no effect on the desktop
demo. It exists purely to satisfy the export check. It is the only rendering-
related project setting touched by this port, and it is not a degradation.

### Verify the APK actually contains the libraries

```sh
unzip -l bin/box3d_demo.apk | grep '\.so$'
```

```
lib/arm64-v8a/libc++_shared.so                                1374336
lib/arm64-v8a/libgodot_android.so                            76217912
lib/arm64-v8a/libbox3d_godot.android.template_debug.arm64.so  1904408
lib/x86_64/libc++_shared.so                                   1337488
lib/x86_64/libgodot_android.so                               81167720
lib/x86_64/libbox3d_godot.android.template_debug.x86_64.so    2009168
```

Both ABIs present, our library alongside Godot's, and no `armeabi-v7a`/`x86`
directories (matching the preset).

### `libc++_shared.so` — a dependency that works by Godot's grace

Our library does **not** statically link the C++ runtime on Android:

```sh
llvm-readelf -d libbox3d_godot.android.template_debug.arm64.so | grep NEEDED
#   NEEDED  libc++_shared.so
#   NEEDED  libm.so / libdl.so / libc.so
```

Compare `godot-cpp/tools/linux.py:47`, which *does* pass
`-static-libgcc -static-libstdc++`. `android.py` passes no such flag. So on
Android the extension needs `libc++_shared.so` to exist at load time — and if
it did not, this would be exactly the silent `dlopen` failure described in §1.

It works because **Godot's own export template already ships
`libc++_shared.so` for all four ABIs**, and Android resolves it from the same
`lib/<abi>/` directory. Worth knowing: this is a property of Godot's packaging
that we depend on, not something this build guarantees. If you ever switch to a
custom Gradle template that omits it, this breaks with a `dlopen failed:
library "libc++_shared.so" not found` and no other clue.

---

## 6. Findings on the risk areas

### 16 KB page size — aligned by default, no flag needed (**verified**)

Android 15+ and current Play requirements expect `.so` files aligned for 16 KB
pages. godot-cpp passes **no** page-size linker flag (`grep -rn
"max-page-size\|16384" tools/ SConstruct` → nothing). It does not need to:
**NDK r28 aligns to 16 KB by default.** Measured on the built library:

```sh
llvm-readelf -l demo/bin/libbox3d_godot.android.template_debug.arm64.so | grep LOAD
#  LOAD  0x000000 ... R    0x4000
#  LOAD  0x064890 ... R E  0x4000
#  LOAD  0x1cbce0 ... RW   0x4000
#  LOAD  0x1d06c0 ... RW   0x4000
```

`0x4000` = 16384 on every LOAD segment, matching Godot's own
`libgodot_android.so`. **`-Wl,-z,max-page-size=16384` is therefore
unnecessary** — adding it would be cargo cult. If you ever downgrade below NDK
r28, re-check this; the flag becomes necessary again.

### SIMD / NEON — already correct, no change (**verified**)

Confirmed by preprocessing `core.h` through the actual NDK clang rather than
by reading the `#if` ladder:

```
--target=aarch64-linux-android24 -march=armv8-a
  -> B3_PLATFORM_ANDROID   defined
  -> B3_PLATFORM_LINUX     NOT defined
  -> B3_CPU_ARM            defined
  -> B3_SIMD_NEON          defined
```

`__aarch64__` → `B3_CPU_ARM` → `B3_SIMD_NEON`, automatically, with
`B3_SIMD_WIDTH 4`. **`BOX3D_DISABLE_SIMD` is not used and must not be** — it is
a diagnostic, and forcing `B3_SIMD_NONE` costs real solver performance.

### `timer.c`'s `__linux__` vs `B3_PLATFORM_ANDROID` split — holds (**verified**)

`core.h` checks `__ANDROID__` *before* `__linux__`, so on Android
`B3_PLATFORM_ANDROID` is defined and `B3_PLATFORM_LINUX` is not. But `timer.c`
ignores the `B3_PLATFORM_*` macros and branches on raw `__linux__`
(lines 6, 227, 342). Android **does** define `__linux__`, confirmed under the
NDK compiler above.

So `timer.c` takes the pthread/POSIX branch, picking up `pthread`,
`semaphore.h`, `sched.h`, and `pthread_setname_np` — all provided by bionic.
It compiles and links cleanly, and the `worker_count=4` multithreaded-stepping
test passes on the device (§8).

The two files still disagree about what Android *is*, and it works by luck
rather than design. `B3_PLATFORM_LINUX` is defined-but-never-used anywhere in
the tree. **No guards were changed** — the behaviour is correct today and
changing it would be churn with real regression risk for zero benefit. It is
worth knowing this is load-bearing luck if `timer.c` is ever refactored.

### Min API level

API 24, godot-cpp's clamped default. Consistent with `core.c` special-casing
Android to use `posix_memalign` instead of `aligned_alloc` (the latter is
absent on older Android API levels) — that special case is Catto's, deliberate,
and needs nothing from us.

### arm32 does not build — an upstream Box3D limitation (**not fixed; by decision**)

`scons platform=android arch=arm32` **fails**:

```
src/contact_solver.c:883:9: error: call to undeclared function 'vdivq_f32'
src/contact_solver.c:888:9: error: call to undeclared function 'vsqrtq_f32'
```

**Diagnosis.** `core.h:41` groups 32-bit and 64-bit ARM together:

```c
#elif defined( __aarch64__ ) || defined( _M_ARM64 ) || defined( __arm__ ) || defined( _M_ARM )
    #define B3_CPU_ARM
```

and then any `B3_CPU_ARM` selects `B3_SIMD_NEON`. But Box3D's NEON code uses
`vdivq_f32` and `vsqrtq_f32` — **vector divide and square root, which do not
exist in ARMv7-A NEON.** They are AArch64-only. ARMv7 NEON offers only
reciprocal *estimate* instructions. godot-cpp compiles `arch=arm32` as
`--target=armv7a-linux-androideabi24 -march=armv7-a -mfpu=neon`, which defines
`__ARM_NEON` but not `__aarch64__` — straight into the gap.

Proven in isolation:

```sh
echo '#include <arm_neon.h>
float32x4_t d(float32x4_t a, float32x4_t b){return vdivq_f32(a,b);}' > /tmp/t.c
clang --target=armv7a-linux-androideabi24 -march=armv7-a -mfpu=neon -c /tmp/t.c   # error
clang --target=aarch64-linux-android24    -march=armv8-a            -c /tmp/t.c   # OK
```

This is upstream Box3D's NEON path silently assuming 64-bit ARM. It is not
caused by this port, and no build flag fixes it.

**Decision: arm32 is not shipped.** arm64 covers every Android device since
roughly 2017, and Google Play has required 64-bit since 2019. The alternatives
were considered and rejected:

- *Fix `core.h` so NEON is selected only on `__aarch64__`*, letting arm32 fall
  back to `B3_SIMD_NONE`. This is arguably the correct upstream fix and worth
  reporting to Box3D upstream — but it edits vendored upstream source, affects
  every arm32 platform rather than just Android, and diverges this fork's
  `src/` from upstream for a target we do not ship.
- *`BOX3D_DISABLE_SIMD` for the arm32 build only*. Rejected: it is a
  diagnostic, not a fix; it costs real performance and hides a bug that
  `core.h` should express properly.

If arm32 is ever needed, the `core.h` guard fix is the right approach, and it
belongs upstream.

---

## 7. Every problem hit, with diagnosis

| # | Symptom | Diagnosis | Fix |
|---|---|---|---|
| 1 | `arch=arm32`: `call to undeclared function 'vdivq_f32'` | Upstream Box3D NEON path uses AArch64-only intrinsics; `core.h` treats `__arm__` and `__aarch64__` alike | Not fixed by decision — arm32 dropped (§6) |
| 2 | `ConfigFile parse error ... Unexpected identifier 'arm32'`, extension stopped loading entirely | `.gdextension` is a Godot ConfigFile; comments are `;`, not `#`. A `#` comment broke the whole manifest | Use `;` |
| 3 | `Cannot export ... A valid Java SDK path is required in Editor Settings` | `export/android/java_sdk_path` was empty | Point it at the JRE. A full JDK is *not* needed with prebuilt templates |
| 4 | `ETC2/ASTC texture compression is required for Android export` | Godot's blanket export gate | `textures/vram_compression/import_etc2_astc=true`. No-op here — the demo has no textures |
| 5 | Emulator segfaults (rc=139) on boot | `-gpu swiftshader_indirect`, `-gpu guest`, `-gpu off` all crash on this host; emulator's Vulkan loader lib is missing | Use `-gpu host` |
| 6 | Emulator boots, then vanishes | Launcher process exiting took the emulator with it | Run the emulator *as* the long-lived process, not via `nohup` from a shell that exits |
| 7 | App launches, Vulkan initialises, **scene never runs**; `ERROR: Couldn't present to Vulkan queue (VkResult error 5)` | Emulator Vulkan (gfxstream) present path is broken — occurs with *and* without a window. **A rendering problem, not an extension problem** | Force `--rendering-method gl_compatibility` for emulator runs, via the preset's `command_line/extra_args`. Not a project change |
| 8 | `[samples] ALL -> PASS` on device with **zero** per-sample lines | **A false pass.** `test_samples.gd` enumerated `res://samples` filtering `.tscn`, but exported builds contain only `ball_pit.tscn.remap` — so it tested nothing and the empty loop left `_all_ok` true | Strip `.remap` before matching, and fail explicitly when zero scenes are found (§8) |
| 9 | Demo renders cube sides black; `Too many instances using shader instance variables ... Maximum items supported by this hardware is: 4096` | The GLES3 backend caps instance shader variables at 4096 *in hardware*; the Cube Pile exceeds it. An artifact of the `gl_compatibility` fallback from #7 | **Not fixed, and not fixable via project settings** — verified that a `buffer_size.mobile` override makes it *worse*, since the value is clamped to the hardware max regardless. Renders under Vulkan on real hardware are untested |
| 10 | `FATAL: Avd's CPU Architecture 'arm64' is not supported by the QEMU2 emulator on x86_64 host` | Google's emulator refuses arm64 images on x86 hosts. It *ships* `qemu-system-aarch64`, but gates it to ARM hosts (Apple Silicon) | No workaround. arm64 AArch64 code was executed via `qemu-user` instead (§8) |

### On the harness fix (#8) — the one test-code change

`demo/tests/test_samples.gd` now strips the `.remap` suffix before matching,
and — importantly — **fails loudly when it finds no scenes** rather than
reporting a vacuous PASS. Before this, an exported build's sample harness
claimed success having executed nothing. Linux output is byte-identical to
before the change (30 lines, all PASS); the fix only affects exported builds,
where it turned 1 meaningless line into 29 real ones.

---

## 8. Verification

### Linux, before and after (**proof nothing broke**)

```sh
GODOT=/path/to/Godot_v4.7-stable_linux.x86_64
DEMO=/path/to/box3d-android/godot/demo
"$GODOT" --headless --path "$DEMO" --import
"$GODOT" --headless --path "$DEMO" res://tests/test_features.tscn -- --selftest
"$GODOT" --headless --path "$DEMO" res://tests/test_samples.tscn  -- --selftest
```

Both exit 0 and end in `ALL -> PASS`. Output after all changes is **diff-clean
against the pre-change baseline**: 42 `[test]` lines, 30 `[samples]` lines.

Two notes for whoever runs this next:

- The harness tags lines **`[test]`** and `[samples]`; `--selftest` is the
  *flag*, not the tag. Grepping for `[selftest]` finds nothing.
- The **first** `--import` on a clean tree exits 134 (SIGABRT) during editor
  teardown, *after* "Verifying GDExtensions" succeeds. A second `--import`
  exits 0. This is pre-existing and unrelated to Android.

### Android — emulator

```sh
avdmanager create avd -n box3d_x86_64 -k "system-images;android-35;google_apis;x86_64" -d pixel_6
emulator -avd box3d_x86_64 -no-audio -no-boot-anim -gpu host -cores 4 -memory 2048 -no-snapshot
```

`-gpu host` is required on this machine; the software rasterizers segfault
(§7 #5). KVM must be available (`ls /dev/kvm`).

The strongest available check is to make the **existing headless harness** the
APK's main scene and read its assertions back over `logcat` — this proves the
physics binding independently of whether anything renders correctly:

```sh
# temporarily: run/main_scene="res://tests/test_features.tscn"
#              command_line/extra_args="--rendering-method gl_compatibility"
godot --headless --path . --export-debug "Android" bin/box3d_test.apk
adb install -r bin/box3d_test.apk
adb logcat -c
adb shell am start -n org.box3d.godot.samples/com.godot.game.GodotAppLauncher
adb logcat -v brief -s godot:V
```

(The launcher activity is `com.godot.game.GodotAppLauncher`, **not**
`GodotApp`. Resolve it with
`adb shell cmd package resolve-activity --brief <package>`.)

**Result on the emulator (x86_64, API 35), verbatim:**

```
Godot Engine v4.7.stable.official.5b4e0cb0f
OpenGL API OpenGL ES 3.1 ... Android Emulator OpenGL ES Translator
[test] layer/mask: matching body rests on floor -> PASS
[test] distance joint holds a swinging body at its length (max err 0.003) -> PASS
[test] continuous on: fast body stopped by thin wall -> PASS
[test] continuous off: fast body tunnels through wall -> PASS
[test] wheel joint: suspension carries the chassis (y 0.87) -> PASS
[test] multithreaded stepping (worker_count=4) simulates correctly -> PASS
... (42 total)
[test] ALL -> PASS
```

and, with the §7 #8 harness fix, all 29 sample scenes:

```
[samples] ball_pit.tscn -> PASS
... (29 total)
[samples] ALL -> PASS
```

That is not "the app launched". Bodies fall and rest, collide, tunnel or don't
per the CCD flag, joints hold to 0.003, motors drive, and the multithreaded
solver steps correctly — **on Android**.

`adb logcat` is clean of GDExtension load errors: no `dlopen` failure, no
"Can't open GDExtension dynamic library", no missing-class errors.

### Android — arm64 (AArch64/NEON), via `qemu-user`

No physical arm64 device was available, and **an arm64 emulator is impossible on
an x86_64 host** — Google's emulator refuses outright (§7 #10). So the arm64
code path was exercised a different way: by compiling **Box3D's own unit test
suite** (`test/`, which upstream ships) for `aarch64-linux-android` as a
**static** binary and running it under `qemu-user`.

Why this is meaningful rather than a stunt: the test binary is compiled by the
**same NDK clang, with the same `--target=aarch64-...`, `-march=armv8-a`,
`-std=gnu17` and `-ffp-contract=off`**, over the **same `src/*.c`** that goes
into the shipped `.so`. It contains 5529 NEON vector instructions
(`llvm-objdump -d | grep -cE "fdiv\s+v|fsqrt\s+v|fmul\s+v"`). It is the same
NEON code, genuinely executing.

`qemu-user` needs no root and no install — extract Fedora's own signed package:

```sh
dnf download qemu-user-static-aarch64          # no sudo required
rpm2cpio qemu-user-static-aarch64-*.rpm | cpio -idm
QEMU=./usr/bin/qemu-aarch64-static

CLANG=$ANDROID_HOME/ndk/28.1.13356709/toolchains/llvm/prebuilt/linux-x86_64/bin/clang
$CLANG --target=aarch64-linux-android24 -march=armv8-a \
       -std=gnu17 -ffp-contract=off -static -O2 \
       -Iinclude -Isrc -Ishared -Iextern \
       test/*.c src/*.c shared/*.c -lm -o box3d_test_arm64

$QEMU ./box3d_test_arm64
```

**Result: all 22 tests / 193 subtests pass on AArch64**, including
`DeterminismTest`, `MathTest`, `ManifoldTest`, `CreateHullDeterminismTest`,
`JointTest`, and `WorldTest`:

```
All Box3D tests passed!
Test duration = 19.81 s        (vs 0.85 s native x86_64 -- ~23x, TCG overhead)
```

#### The determinism result — the strongest single piece of evidence

`test/test_determinism.c` hardcodes a **bit-exact cross-platform expectation**:

```c
#define EXPECTED_SLEEP_STEP 308
#define EXPECTED_HASH 0x1E5EDD79
...
ENSURE( data.sleepStep == EXPECTED_SLEEP_STEP );
ENSURE( data.hash == EXPECTED_HASH );
```

It simulates 500 steps of falling ragdolls and hashes the resulting world
state. Building the identical suite for both Android ABIs gives:

| Build | SIMD path | Hash after 500 steps | Sleep step |
|---|---|---|---|
| aarch64-linux-android (qemu) | **NEON** (`vdivq_f32`, `vsqrtq_f32`) | **`0x1E5EDD79`** | 308 |
| x86_64-linux-android (native) | **SSE2** | **`0x1E5EDD79`** | 308 |

**The NEON and SSE2 builds produce bit-identical simulation state.** This is
direct evidence that:

- The NEON path is not merely "compiles and doesn't crash" — it is numerically
  correct to the bit.
- **`-ffp-contract=off` is doing its job on ARM.** If clang had contracted any
  `a*b+c` into an FMA on AArch64, this hash would diverge and the assertion
  would fail. This is the flag's entire purpose, and here is the proof it
  matters — it is not decoration.

**What this does not prove.** Be precise about this:

- `qemu-user` *emulates* AArch64. It is not real silicon. QEMU's NEON
  implementation is accurate and the bit-exact hash match is strong evidence,
  but a physical CPU has not run this code.
- This exercises the **Box3D C core only**. The C++ wrapper in `godot/src/` and
  Godot's `dlopen` of the arm64 `.so` are *not* covered.
- The test binary is **statically linked**; the shipped artifact is a dynamic
  `.so` resolving `libc++_shared.so` through bionic. Dynamic loading on arm64
  is not exercised here.

### Diagnosing a crash

If the extension crashes, symbolize rather than guess:

```sh
adb logcat | $ANDROID_HOME/ndk/28.1.13356709/prebuilt/linux-x86_64/bin/ndk-stack \
    -sym godot/demo/bin
```

---

## 9. What is tested and what is NOT

Read this section before repeating any claim from this document.

### Verified by execution

- **The extension loads and runs on Android.** x86_64, API 35 emulator.
- **Physics genuinely simulates on Android.** All 42 binding assertions and all
  29 sample scenes pass on-device, via the project's own harness.
- **Linux is not broken.** Post-change output is diff-identical to baseline.
- **All four `.so` files are the intended architecture** (`llvm-readelf -h`:
  AArch64 / X86-64 as intended) **and 16 KB aligned** (`0x4000` on every LOAD).
- **The entry symbol is exported** `GLOBAL DEFAULT` in every library.
- **The APK packages both ABIs correctly** under `lib/arm64-v8a/` and
  `lib/x86_64/`.
- **The demo runs on Android** and its UI and 3D scene render.
- **The AArch64/NEON code path executes correctly** — Box3D's own suite, 22
  tests / 193 subtests, built by the NDK for `aarch64-linux-android` and run
  under `qemu-user` (§8).
- **NEON and SSE2 are bit-identical.** Both Android builds produce state hash
  `0x1E5EDD79` after 500 ragdoll steps, proving `-ffp-contract=off` holds on
  ARM (§8).
- **`template_release` runs.** The Linux release library passes all 42 + 30
  assertions (tested by temporarily pointing the manifest's debug key at it).
- **The arm64 `.so` loads and runs under Godot on an arm64 device**, and all
  **42 binding assertions pass** there — run in two halves because of the Robo
  time limit (§9): assertions 1-22 from `test_features.tscn`, 23-42 from the
  tail scaffold, `[test] TAIL -> PASS`, zero failures. This covers the arm64
  `dlopen`, the C++ wrapper on ARM, bionic's resolution of `libc++_shared.so`,
  and the NEON solver — including `worker_count=4` multithreaded stepping.
  Device: `MediumPhone_ps16k.arm` / API 36 / Firebase Test Lab.
- **16 KB pages work at runtime.** The library loaded and ran on
  `sdk_gphone16k_arm64` — a genuine 16 KB-page kernel, where a misaligned `.so`
  would fail to load outright. No alignment error, no `dlopen` failure. The
  decision not to pass `-Wl,-z,max-page-size=16384` (§6) is therefore backed by
  execution, not only by reading `0x4000` out of an ELF header.
- **It runs on a real phone, under real Vulkan.** Firebase Test Lab,
  **realme C53 (`RE58C2`), API 35** — a physical handset:

  ```
  Godot Engine v4.7.stable.official.5b4e0cb0f
  Vulkan 1.3.278 - Forward Mobile - Using Device #0: ARM - Mali-G57
  [test] ... -> PASS      (31 assertions, 0 failures)
  ```

  This is the stock APK with **no `gl_compatibility` override**, so it took
  Godot's real default renderer on a real **ARM Mali-G57** with the vendor's
  own Vulkan driver, resolved `lib/arm64-v8a`, and simulated correctly.
  **Zero `Couldn't present to Vulkan queue` errors** — versus a constant
  stream of them in every emulated environment. That confirms the Vulkan
  failures documented in §7 #7 are emulation artifacts (llvmpipe / SwiftShader
  / gfxstream), not a property of this port.

### NOT tested — be explicit about these

- **Only one physical device, and not a flagship.** The realme C53 is a
  Mali-G57 / Unisoc part. A Snapdragon/Adreno or Exynos device has not been
  tried — a OnePlus 11 run sat `PENDING` for 60+ minutes on the free tier and
  never executed. Vulkan driver behaviour does vary by vendor.
  (Practical note: **device choice, not the free tier, is the bottleneck.** The
  flagship never dequeued; the realme started in 37 seconds.)
- **No single run has executed all 42 assertions on real silicon.** Robo's
  ~17 s teardown (§9) caps a run at ~22-31 of them. Coverage is complete but
  *assembled*: 42/42 on arm64 (Arm virtual, in two halves), 31/42 on the real
  phone under Vulkan, and Box3D's own C suite bit-exact on AArch64 under
  `qemu-user`. No assertion has ever failed in any environment.
- **The Android `template_release` libraries have never been run.** Every
  on-device run used `template_debug`. The *Linux* release library passes the
  full suite.
- **arm32 does not build at all** (§6).
- **An arm64 *emulator* is impossible on an x86_64 host** — not merely slow.
  Google's emulator refuses: `FATAL: Avd's CPU Architecture 'arm64' is not
  supported by the QEMU2 emulator on x86_64 host`. Test Lab's Arm virtual
  devices, or a physical device, are the way around this.
- **The demo's *appearance* on a real phone could not be observed at all** —
  and this is a limitation of the tooling, not a finding about the demo.
  Test Lab's video and screenshots come back **pure black** (mean pixel 0) for
  the whole run on the physical device, while the app is demonstrably alive:
  Vulkan initialises, the scene loads, surface buffers are produced, nothing
  crashes, and the harness passes 31 assertions on that same handset.

  It is a **capture** artifact, not a render failure. The evidence:

  | Environment | Renderer | Capture |
  |---|---|---|
  | local emulator | GL | demo visible (cube pile + UI) |
  | realme C53 (physical) | Vulkan | black |
  | realme C53, `.mobile` overrides | Vulkan | black (identical) |
  | realme C53 | **GL** | **black (identical)** |

  The renderer is not the variable — the device is. Godot draws into a
  `SurfaceView`, and Android's screencap/screenrecord commonly returns black
  for hardware-composited surfaces. Note also that reducing the shadow map
  8192→2048, disabling MSAA and cutting the shader buffer to 64 KB produced a
  **pixel-identical** result: a GPU actually struggling with those settings
  would not render identically when they change. That rules the settings out.

  **Therefore no mobile rendering settings are proposed.** The obvious
  candidates were tested and fixed nothing. Whether the demo's
  desktop-oriented settings (8192 shadow maps, MSAA, 256 KB shader buffer)
  *look* right on a phone remains genuinely **unknown**, and the only way to
  find out is to run it on a device you can physically look at:
  `adb install godot/demo/bin/box3d_demo.apk`. Note the SSAO/SSIL warnings on
  Forward Mobile are cosmetic and expected — those effects are Forward+ only.

  The physics is provably unaffected either way (31 assertions, same device,
  under Vulkan).

### If someone asks you a question you cannot answer

Be aware these are the honest weak points, in order:

1. *"Have you run it on a real phone, under Vulkan?"* — **Yes.** realme C53,
   API 35, physical, via Test Lab: `Vulkan 1.3.278 - Forward Mobile - ARM
   Mali-G57`, 31 assertions, zero failures, zero present errors, stock APK with
   no renderer override. Caveat: **one** device, a Mali/Unisoc part. No
   Adreno/Snapdragon or Exynos device was reached.
2. *"Did any single run execute all 42 assertions on hardware?"* — **No.**
   Robo tears the session down at ~17 s, capping a run at ~22-31 assertions.
   Coverage is complete but **assembled** across runs: 42/42 on arm64 (Arm
   virtual, in two halves), 31/42 on the real phone under Vulkan, plus Box3D's
   C suite bit-exact on AArch64. **No assertion has failed anywhere.** If you
   want one green 42/42 on hardware, that needs a game-loop test (§9) or an
   `adb` run on a device you own.
3. *"So could NEON be wrong on real silicon?"* — It is not: 31 assertions pass
   on a physical Mali-G57 arm64 handset. Independently, the NEON build
   reproduces a **bit-exact** 500-step simulation hash (`0x1E5EDD79`) matching
   the SSE2 build (§8).
4. *"Why did Vulkan fail everywhere except the phone?"* — Because every
   emulated environment here (gfxstream on the local emulator, llvmpipe and
   SwiftShader on Arm virtual devices) has a broken present path. Real hardware
   produced **zero** such errors. The `gl_compatibility` override in the local
   instructions is an *emulator workaround*, not something the port needs.
5. *"Is the release build good?"* — The **Linux** release library passes the
   full suite. No **Android** release APK has been launched.
6. *"Why is `timer.c` allowed to disagree with `core.h` about Android?"* — It
   works because bionic provides the POSIX APIs the `__linux__` branch wants.
   Correct today, and luck rather than design (§6).
7. *"Why no 16 KB page linker flag?"* — NDK r28 defaults to 16 KB alignment;
   the binary was measured (`0x4000` on every LOAD) **and** loaded successfully
   on a real 16 KB-page kernel (`sdk_gphone16k_arm64`), where a misaligned
   library would not load at all. Downgrade the NDK and this changes.

8. *"Does the demo actually look right on a phone?"* — **Unknown, and not for
   want of trying.** Test Lab's capture returns black for Godot's `SurfaceView`
   on the physical device under *both* Vulkan and GL, so the screen could not
   be observed. The app is alive underneath (scene loads, buffers produced, 31
   assertions pass). The heavy-settings theory was tested and **disproved** —
   `.mobile` overrides for shadow map / MSAA / shader buffer changed the output
   not at all. Run `adb install godot/demo/bin/box3d_demo.apk` on a phone you
   can look at; that is the only way to answer it.

Remaining work is optional rather than load-bearing: a second GPU vendor
(Adreno/Exynos), an Android `template_release` run, a single uninterrupted
42/42 on hardware via a game-loop test, and eyeballing the demo on a physical
device. **Nothing known is broken.**

### Closing the gap without owning a phone: Firebase Test Lab

`godot/tools/testlab_arm64.sh` runs the harness APK on **real arm64 hardware**
via Firebase Test Lab and greps the result out of logcat. Firebase's free
(Spark) tier includes a small daily quota of physical-device runs, which is
enough for this.

```sh
~/google-cloud-sdk/bin/gcloud auth login
~/google-cloud-sdk/bin/gcloud config set project <your-firebase-project-id>
./godot/tools/testlab_arm64.sh                  # or: ./testlab_arm64.sh oriole 33
```

Things that matter and are easy to get wrong:

- **Not every Test Lab device is arm64.** Many virtual devices are **x86** —
  those would run the x86_64 `.so` we already test locally and touch the arm64
  library not at all, while presenting as a green Android result. Use either a
  `form=PHYSICAL` device or an explicitly **Arm** virtual device
  (`*.arm`, e.g. `MediumPhone_ps16k.arm`). Confirm from the logcat that the
  device resolved `lib/arm64-v8a`.
- **`MediumPhone_ps16k.arm` is worth knowing about**: an Arm virtual device
  with a **16 KB page size** (`sdk_gphone16k_arm64`). It is the only way here
  to test 16 KB page loading at runtime — a misaligned `.so` does not load at
  all on such a kernel. See §6.
- The Robo test is only a launcher; **Robo may report the run as "failed"
  because the app exits by itself within seconds.** That is expected. The
  logcat is the result.

#### The Robo time limit — why one run cannot cover all 42 assertions

Robo exhausts its crawl in **~9 seconds** on the harness scene (there is no UI
to explore), and Test Lab tears the session down at **~17 seconds**. The full
harness needs ~34 s, so it is cut off mid-run — deterministically after 22
assertions. Symptoms that this is what you are seeing: an identical assertion
count every run, no crash, no ANR, and the logcat simply ending.

**`--fixed-fps` does not fix this on Android.** On desktop it disables
real-time synchronisation and the harness drops from 30.2 s to 0.58 s (a 52x
speedup, byte-identical assertions — worth using for the Linux/CI suite). On
Android the platform drives Godot's main loop from vsync, so physics stays
pinned to 60 Hz real time and the flag has no effect. It *is* passed correctly
(verify with `unzip -p app.apk assets/_cl_ | od -c`; note `strings` hides
short tokens like `60`, which is misleading).

The workaround used here was to run the harness in **two halves** — the stock
`test_features.tscn` (assertions 1-22), then a temporary scaffold subclassing
it to run only the tail (`_test_wheel_joint` onward, assertions 23-42):

```gdscript
extends "res://tests/test_features.gd"
func _ready() -> void:
    await _test_wheel_joint()
    ...
    await _test_solver_tuning()
    print("[test] TAIL -> ", "PASS" if _all_ok else "FAIL")
    get_tree().quit(0 if _all_ok else 1)
```

The proper fix, if this is ever automated, is a Test Lab **game-loop** test
(`--type game-loop`), which runs the app for a fixed duration without a
crawler. It needs a `com.google.intent.action.TEST_LOOP` intent filter in
`AndroidManifest.xml`, which means enabling Godot's Gradle custom build — and
that needs a real JDK, not the JRE this build otherwise gets by with.

For a **visual** check, point the runner at the demo APK instead; Test Lab
records video and screenshots:

```sh
APK=godot/demo/bin/box3d_demo.apk ./godot/tools/testlab_arm64.sh
```

Rebuild the APK with:

```sh
cd godot/demo
sed -i 's|run/main_scene="res://main.tscn"|run/main_scene="res://tests/test_features.tscn"|' project.godot
godot --headless --path . --export-debug "Android" bin/box3d_testlab.apk
git checkout project.godot        # <- do not forget
```
