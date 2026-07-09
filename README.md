# Box3D for Godot

A **[Godot 4](https://godotengine.org) GDExtension** that embeds
**[Box3D](https://github.com/erincatto/box3d)** Erin Catto's 3D rigid-body
physics engine and exposes it as ready-to-use nodes: `Box3DWorld`,
`Box3DBody`, the joints, and a character controller.

This is a fork of **[erincatto/box3d](https://github.com/erincatto/box3d)**. The
upstream engine sources are unchanged; everything Godot-specific lives in
**[`godot/`](godot/)**. The original Box3D README is preserved [below](#box3d).

> ⚠️ **Very early / experimental.** Box3D itself is v0.1.0 and this binding is
> young expect rough edges, missing pieces, and API churn. It's not
> production-ready; it's a starting point to build on.

### What's here

- Targets **Godot 4.7**. One-command build (`scons`) compiles Box3D from source
  into the extension no prebuilt engine binary required.
- Covers worlds; static/kinematic/dynamic bodies; box/sphere/capsule/cylinder/
  cone/convex-hull/triangle-mesh colliders; the full joint set (hinge, slider,
  distance, ball, fixed, motor, wheel, parallel); contact & sensor events;
  ray/shape/overlap queries; a character controller; continuous collision; and
  live solver tuning.
- Ships a **sample browser** demo (~28 samples stacks, ragdoll, a drivable
  car, joints, queries, and toys).



https://github.com/user-attachments/assets/ce0d9806-9d35-4d24-9457-4ab83e761230



https://github.com/user-attachments/assets/b3b04613-ed57-417e-822d-665f057b7d5c



https://github.com/user-attachments/assets/33752918-c3a2-4899-821c-bf13d9adce11



**→ Get started:** see **[`godot/README.md`](godot/README.md)**.

Inspired by the [`box3d-unity`](https://github.com/timskap/box3d-unity) binding,
which does the same for Unity.

---

<sub>The rest of this file is the upstream Box3D README.</sub>

# Box3D

[![Build Status](https://github.com/erincatto/box3d/actions/workflows/build.yml/badge.svg)](https://github.com/erincatto/box3d/actions)
[![CLA assistant](https://cla-assistant.io/readme/badge/erincatto/box3d)](https://cla-assistant.io/erincatto/box3d)

![Box3D Logo](https://box2d.org/images/logo.svg)

Box3D is a 3D physics engine for games.

[![Introducing Box3D](https://img.youtube.com/vi/jr_Fzl2XwKU/maxresdefault.jpg)](https://www.youtube.com/watch?v=jr_Fzl2XwKU)

## Features

### Collision

- Continuous collision detection
- Contact events
- Convex hulls, capsules, spheres, triangle meshes, and height fields
- Multiple shapes per body
- Collision filtering
- Ray casts, shape casts, and overlap queries
- Sensor system
- Character mover

### Physics

- Robust _Soft Step_ rigid body solver
- Continuous physics for fast translations and rotations
- Island based sleep
- Revolute, prismatic, distance, motor, weld, and wheel joints
- Joint limits, motors, springs, and friction
- Joint and contact forces
- Body movement events and sleep notification

### System

- Data-oriented design
- Written in portable C17
- Extensive multithreading and SIMD
- Optimized for large piles of bodies
- Cross platform determinism
- Recording and replay

### Samples

- Uses sokol to run with D3D11 on Windows, Metal on macOS, and OpenGL 4.5 on Linux.
- Graphical user interface with imgui.
- Many samples to demonstrate features and performance.

## Building all platforms

- Install [CMake](https://cmake.org/)
- Install [git](https://git-scm.com/)
- Ensure these run from the command line

## Building with CMake presets (recommended)

This uses the presets in `CMakePresets.json`.

- Windows: `cmake --preset windows` then `cmake --build --preset windows-release`
- Linux: `cmake --preset linux-release` then `cmake --build --preset linux-release`
- macOS: `cmake --preset macos` then `cmake --build --preset macos-release`

Run the samples app (must be in the Box3D directory).

- Windows: `.\build\bin\Release\samples.exe`
- Linux: `./build/bin/samples`
- macOS: `./build/bin/Release/samples`

## Building for Visual Studio

- Install [Visual Studio](https://visualstudio.microsoft.com/)
- Run `build_vs2026.bat`
- Open and build `build/box3d.slnx`

## Building for Linux

- Run `build.sh` from a bash shell
- Results are in the build sub-folder

## Building for Xcode

- mkdir build
- cd build
- cmake -G Xcode ..
- Open `box3d.xcodeproj`
- Select the samples scheme
- Build and run the samples

## Building for Web

- [Emscripten SDK](https://emscripten.org/docs/getting_started/downloads.html)
- `emcmake cmake -B build -DBOX3D_SAMPLES=OFF`
- `cmake --build build`

Box3D uses SSE2 with WebAssembly. Define `BOX3D_DISABLE_SIMD` to disable SSE2.

## Building and installing

- mkdir build
- cd build
- cmake ..
- cmake --build . --config Release
- cmake --install . (might need sudo)

## Using Box3D in your project

The core library has no dependencies beyond the C runtime (and `libm` on Unix). Linking it
gives you the `box3d::box3d` target.

I recommend to use FetchContent:

```cmake
include(FetchContent)
FetchContent_Declare(box3d
  GIT_REPOSITORY https://github.com/erincatto/box3d.git
  GIT_TAG v0.1.0)
FetchContent_MakeAvailable(box3d)

target_link_libraries(my_app PRIVATE box3d::box3d)
```

For a vendored copy or git submodule, point `add_subdirectory` at it:

```cmake
add_subdirectory(extern/box3d)

target_link_libraries(my_app PRIVATE box3d::box3d)
```

To use a copy installed with `cmake --install`, find the package:

```cmake
find_package(box3d 0.1 REQUIRED)

target_link_libraries(my_app PRIVATE box3d::box3d)
```

See [`docs/hello.md`](docs/hello.md) for a minimal first program.

## Compatibility

The Box3D library and samples build and run on Windows, Linux, and Mac.

You will need a compiler that supports C17 to build the Box3D library.

You will need a compiler that supports C++20 to build the samples.

Box3D uses SSE2 and Neon SIMD math to improve performance. SIMD can be disabled by defining `BOX3D_DISABLE_SIMD`.

## Documentation

The user manual lives in [`docs/`](docs/) and is built with Doxygen. Enable the `BOX3D_DOCS` CMake option and build the `doc` target.

## Community

- [Discord](https://discord.gg/NKYgCBP)

## Contributing

Pull requests are currently disabled. Instead, please file an issue for bugs or feature requests. For support, please visit the Discord server.

## Giving feedback

Please file an issue or start a chat on discord. You can also use [GitHub Discussions](https://github.com/erincatto/box3d/discussions).

## License

Box3D is developed by Erin Catto and uses the [MIT license](https://en.wikipedia.org/wiki/MIT_License).

## Sponsorship

Support development of Box3D through [Github Sponsors](https://github.com/sponsors/erincatto).

Please consider starring this repository and subscribing to my [YouTube channel](https://www.youtube.com/@erin_catto).

## LLM Usage

LLMs are used in the following areas:

- unit tests
- samples app
- migrating code between Box2D and Box3D
- build configuration
- code reviews
- benchmarking

Elsewhere all code is developed and written by me. I take responsibility for every line of code in Box2D/3D.
