# Box3D for Godot

A Godot 4.6+ GDExtension wrapping [Box3D](https://github.com/erincatto/box3d),
Erin Catto's 3D rigid body physics engine: `Box3DWorld`, `Box3DBody`,
`Box3DCharacterBody`, nine joint types, recording and replay, and the query
and geometry helpers, all as ordinary nodes.

## Install

1. Unzip so that `addons/box3d/` sits next to your `project.godot`.
2. Start (or restart) Godot. Extensions load at startup.
3. Add a node and search for `Box3DWorld`. If it is listed, you are done.

The `bin/` folder holds every platform this release was built for (Windows,
Linux, macOS universal, Android arm64 and x86_64, and threaded web). Godot
exports only the library that matches the target, so the unused ones cost
nothing in your game. Requires Godot 4.6 or newer.

On macOS the library is not signed by Apple. If Godot does not load it, clear
the download quarantine and restart Godot:
`xattr -dr com.apple.quarantine addons/box3d`

The library the editor loads is the `template_debug` one; exported games use
`template_release`. Both are included.

## Docs, demo, source

- Full node and property reference: https://github.com/Stink-O/box3d-godot/blob/main/godot/README.md
- Playable demo of every sample: https://stinkysunstep.itch.io/box3d-godot
- The same demo as a Godot project you can open: `0-box3d-demo-project.zip` on
  the release this zip came from, https://github.com/Stink-O/box3d-godot/releases
- Issues and source: https://github.com/Stink-O/box3d-godot
