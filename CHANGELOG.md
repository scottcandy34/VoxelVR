# Changelog

## 1.1.0 — 2026-10-27

### Fixed
- **VR never started.** The options row only checks the OS, so it still
  appeared, but the first frame called `require("ffi")` on the game thread
  and the mod sandbox rejected it (`ffi` is "arbitrary C calls"). The
  failure was logged once and then latched until the row was toggled.
  OpenXR never got as far as creating an instance, on Horizon Link and
  SteamVR alike.
- The session, the OpenXR loader, and a hidden GL context now run on a
  `love.thread` worker (`compute` permission). Eye canvases and the UI
  panel are read back on the game thread and uploaded in the worker.
  Hosts that still allow FFI keep the old in-process blit.
- Dramatic Shape **1.9.3** drives `exports.update` from the voxel tick
  again (that is the call 1.8.5 made). This mod wraps `Game:update` only
  when the main mod does not export `drivesVR`, so the two do not both
  submit a frame.

### Notes
- Needs the `compute` permission. Windows x64 + an OpenXR runtime, same
  as before.
- A separate GL context can be rejected by some runtimes
  (`XR_ERROR_GRAPHICS_DEVICE_INVALID`). The VR row's failure text is that
  status. Pixel readback is heavier than the old GPU blit and will not
  hold a headset's full rate on a busy scene.

## 1.0.0 — 2026-08-21

Initial release of **VoxelVR**, split out of Dramatic Shape Voxel Mod so the
core voxel experience no longer loads LuaJIT FFI or the OpenXR loader.

### Added
- OpenXR / PCVR session (Windows) as a companion to `DRAMATIC_SHAPE`
- Hybrid library bridge: local `VR*` / `Diorama` / `Pokedex` modules, with
  fall-through to the main mod’s `exports.lib` for shared code
- `ModSetting` copy so **VR** and **SMOOTH TURN** register on this mod’s
  manager page and on the live OPTIONS menu
- `mod.find("DRAMATIC_SHAPE")` wiring for `cycleVoxel` / `setVoxelLevel`
- Exports (`active`, `mirror`, `invalidate`, `setPaletteFor`) for the main
  mod’s soft mirror and invalidate hooks
- Ships `assets/vr/openxr_loader.dll` (Khronos loader)

### Notes
- Depends on Dramatic Shape Voxel Mod **1.9.0+**
- Platform: Windows x64 + OpenXR runtime only
