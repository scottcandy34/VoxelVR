-- VoxelVR companion mod
--
-- Depends on DRAMATIC_SHAPE. Bridges into the main mod's library via
-- mod.find("DRAMATIC_SHAPE").exports.lib so VR can reuse ModSetting-free
-- copies of VoxelScene, FirstPerson, etc., while loading its own VR*.lua
-- modules from this package.
--
-- Settings: VR + SMOOTH TURN appear on the OPTIONS menu (and this mod's
-- manager page) when the platform supports OpenXR.

local mod = ...

-- ------- resolve the main voxel mod (hard dependency, already loaded)
local mainInfo = mod.find("DRAMATIC_SHAPE")
if not (mainInfo and mainInfo.exports and mainInfo.exports.lib) then
  error(
    "VoxelVR: Dramatic Shape Voxel Mod (DRAMATIC_SHAPE) is required "
    .. "and must export lib. Enable/update the main mod, then retry.",
    0
  )
end
local MainV = mainInfo.exports.lib

-- ------- hybrid namespace: local VR modules first, then main mod modules
local V = { mod = mod, path = mod.path, main = MainV }

local function chunkFor(rel)
  local source = mod:read(rel)
  if not source then return nil end
  local chunk, err = load(source, "@" .. mod.path .. "/" .. rel)
  if not chunk then
    error(("VoxelVR: %s did not compile: %s"):format(rel, tostring(err)), 0)
  end
  return chunk
end

local modules = {}
function V.require(name)
  local hit = modules[name]
  if hit ~= nil then return hit end

  -- Prefer a file shipped in THIS mod (VR, VRGL, VRXR, VRRig, Diorama,
  -- Pokedex, ModSetting).
  local chunk = chunkFor("lib/" .. name .. ".lua")
  if chunk then
    local value = chunk(V)
    modules[name] = value
    return value
  end

  -- Fall through to the main voxel mod's library.
  local ok, value = pcall(MainV.require, name)
  if ok and value ~= nil then
    modules[name] = value
    return value
  end

  error(("VoxelVR: module %q not found in VR mod or DRAMATIC_SHAPE"):format(name), 0)
end

function V.dlog(msg)
  msg = tostring(msg)
  print("[VoxelVR] " .. msg)
  if mod.log then pcall(function() mod.log:info("%s", msg) end) end
end

V.dlog(("loading; main=%s main.version=%s"):format(
  tostring(mainInfo.version), tostring(mainInfo.exports.version)))

-- ------- load the VR stack (FFI stays isolated here)
local VR = V.require("VR")

-- Wire the ladder helpers the main mod still owns (cycleVoxel / setVoxelLevel
-- were locals of its main.lua; it now exports them for this companion).
if mainInfo.exports.cycleVoxel then
  VR.cycleVoxel = mainInfo.exports.cycleVoxel
end
if mainInfo.exports.setVoxelLevel then
  VR.setVoxelLevel = mainInfo.exports.setVoxelLevel
end

-- ------- settings: manager page + in-game OPTIONS menu
local schema = {}
if VR.supported() then
  schema[#schema + 1] = VR.setting:schema(
    "PCVR through OpenXR on Windows: STANDARD follows the VOXEL ladder; "
    .. "DIORAMA / DIORAMA-MR put the world on a table you can pick up.")
  schema[#schema + 1] = VR.smoothTurn:schema(
    "Turn smoothly with the right stick instead of snapping 45 degrees. "
    .. "Only used in STANDARD first-person VR.")
end
if #schema > 0 then
  mod.options:define(schema)
end

-- Put the same rows on the live OPTIONS menu so players do not have to open
-- the mod manager. Inserted near the top, after DRAMATIC SHAPE's own row when
-- present.
mod.hooks:wrap("ui.options.rows", function(next, game, rows)
  local out = next(game, rows)
  if type(out) ~= "table" then return out end
  if not VR.supported() then return out end

  -- Avoid duplicates if the hook runs more than once
  for _, row in ipairs(out) do
    if type(row) == "table" and row.id == (mod.id .. ":vr") then
      return out
    end
  end

  local insertAt = 1
  for i, row in ipairs(out) do
    if type(row) == "table" and type(row.id) == "string"
       and row.id:find("DRAMATIC_SHAPE", 1, true) then
      insertAt = i + 1
      break
    end
  end

  local vrRow = VR.setting:row()
  -- Prefer a short label on the top-level list
  vrRow.label = "VR"
  table.insert(out, insertAt, vrRow)

  -- SMOOTH TURN only while STANDARD VR is on and not diorama
  if VR.enabled() and not VR.dioramaMode() then
    table.insert(out, insertAt + 1, VR.smoothTurn:row())
  end
  return out
end)

-- Keep the menu list in sync when VR is toggled (same pattern the main
-- mod uses for FULL / 3D-BTL).
mod.events:on("mod.options_changed", function(payload)
  if not (payload and payload.mod == mod.id) then return end
  if payload.key == "vr" or payload.key == "smoothturn" then
    VR.setting:sync(payload.value)
    if payload.key == "smoothturn" then
      VR.smoothTurn:sync(payload.value)
    end
  end
end)

-- ------- per-frame VR drive
do
  local ok, err = pcall(function()
    local Game = require("src.core.Game")
    if Game.dramaticShapeVRHook then return end
    local inner = Game.update
    function Game:update(dt)
      pcall(VR.update, dt)
      return inner(self, dt)
    end
    Game.dramaticShapeVRHook = true
    V.dlog("Game:update wrap installed")
  end)
  if not ok then V.dlog("Game:update wrap failed: " .. tostring(err)) end
end

-- ------- publish exports for the main mod's soft hooks (mirror, active)
mod.exports.VR = VR
mod.exports.lib = V
mod.exports.active = function() return VR.active() end
mod.exports.enabled = function() return VR.enabled() end
mod.exports.mirror = function(sw, sh) return VR.mirror(sw, sh) end
mod.exports.invalidate = function() return VR.invalidate() end
mod.exports.setPaletteFor = function(fn) VR.paletteFor = fn end

-- Let the main mod know a VR companion is present (optional hooks).
if mainInfo.exports.registerVR then
  pcall(mainInfo.exports.registerVR, mod.exports)
end

V.dlog("VoxelVR load complete; supported=" .. tostring(VR.supported()))
