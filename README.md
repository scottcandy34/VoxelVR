# VoxelVR

PCVR / OpenXR companion for the
[Dramatic Shape Voxel Mod](https://github.com/scottcandy34/DramaticShapeVoxelMod-latest).

## Why a separate mod?

The VR implementation uses LuaJIT FFI and a Windows OpenXR loader. That
breaks (or is forbidden) under the Gen1Recomp sandbox and on Android.
Keeping FFI in this optional companion leaves the main voxel mod
sandbox-safe everywhere.

## Requirements

- **Dramatic Shape Voxel Mod** (`DRAMATIC_SHAPE`) **1.9.3+** recommended
  (1.9.0+ still loads; this mod then drives itself from `Game:update`)
- Windows x64
- An OpenXR runtime (SteamVR, Meta Horizon Link, Windows Mixed Reality, …)
- A PCVR headset

The mod sandbox does not allow `require("ffi")` on the game thread. 1.1.0
runs the OpenXR session on a companion thread (manifest permission
`compute`) and copies eye and panel pixels across. That readback is
slower than a GPU blit. Update both mods together.

## Install

1. Install / update Dramatic Shape Voxel Mod to **1.9.3** or newer.
2. Import this mod: **MODS → Import mod .zip**.
3. Enable both mods.

The **VR** options row appears on the OPTIONS menu on Windows when an
OpenXR runtime is present. **SMOOTH TURN** appears while STANDARD VR is on.

## Controls

| Control | Action |
|---------|--------|
| left stick | move |
| A / B | A / B |
| either trigger | START |
| left stick click | step VOXEL ladder (STANDARD) or toggle V-CURVE (DIORAMA) |
| right stick left/right | snap-turn or smooth-turn (1ST) |
| right stick up/down | zoom the model (DIORAMA / tabletop) |
| grips | drag table height (STANDARD) or carry / turn the model (DIORAMA) |

## Repo

https://github.com/scottcandy34/VoxelVR

## License

Code extracted from Dramatic Shape Voxel Mod. OpenXR loader is the
Khronos-shipped binary under Apache License 2.0
(see `assets/vr/LICENSE-openxr_loader.txt`).
