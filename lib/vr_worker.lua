-- OpenXR session host.
--
-- The game thread is sandboxed and cannot require("ffi"), so it cannot
-- bind an OpenXR session. This file is started with love.thread (the
-- "compute" permission) and runs in a fresh Lua state that still has FFI,
-- the real filesystem, and its own GL context. The game thread sends eye
-- and panel pixels; cdata never crosses the channel.
--
-- Args: modPath, quadW, quadH.

local modPath, quadW, quadH = ...
local IN, OUT = "voxelvr.in", "voxelvr.out"

local function send(msg)
  love.thread.getChannel(OUT):push(msg)
end

local function recv()
  return love.thread.getChannel(IN):demand()
end

-- LOVE channels carry plain values only. Poses come out of FFI as numbers
-- almost always, but a cdata float would kill the push, and a nil value
-- is illegal inside a message. Drop both.
local function plain(v, depth)
  if (depth or 0) > 6 then return nil end
  local t = type(v)
  if t == "number" or t == "string" or t == "boolean" then return v end
  if t ~= "table" then
    local n = tonumber(v)
    if n then return n end
    return nil
  end
  local out = {}
  for k, val in pairs(v) do
    local pk = plain(k, (depth or 0) + 1)
    local pv = plain(val, (depth or 0) + 1)
    if (type(pk) == "string" or type(pk) == "number") and pv ~= nil then
      out[pk] = pv
    end
  end
  return out
end

local VRGL, VRXR

local function main()
  love.thread.getChannel(IN):clear()
  love.thread.getChannel(OUT):clear()
  if type(modPath) ~= "string" or modPath == "" then
    error("VR worker started without a mod path", 0)
  end

  local function loadRel(rel)
    local src = love.filesystem.read(modPath .. "/" .. rel)
    if type(src) ~= "string" then error("missing " .. rel, 0) end
    local chunk, err = (loadstring or load)(src, "@" .. modPath .. "/" .. rel)
    if not chunk then error(err, 0) end
    return chunk
  end

  local V = { path = modPath, mod = {} }
  function V.mod:read(rel)
    return love.filesystem.read(modPath .. "/" .. rel)
  end
  -- Bound for real once VRGL's chunk has run. Declared first so the
  -- name the closure closes over is this local, not a global.
  local VRGL_mod = nil
  function V.require(name)
    if name == "VRGL" then return VRGL_mod end
    error("vr worker cannot load " .. tostring(name), 0)
  end

  VRGL = loadRel("lib/VRGL.lua")()
  if not VRGL.ensureContext() then error(VRGL.status(), 0) end
  VRGL_mod = VRGL

  VRXR = loadRel("lib/VRXR.lua")(V)
  if not VRXR.start(tonumber(quadW) or 1024, tonumber(quadH) or 768) then
    error(VRXR.status(), 0)
  end

  send({ ok = true, status = VRXR.status() })

  local heldTime = nil
  while true do
    local msg = recv()
    if type(msg) ~= "table" or msg.op == "stop" then break end
    if msg.op == "begin" then
      heldTime = nil
      if not VRXR.poll() then
        send({ ok = true, alive = false, status = VRXR.status() })
      elseif not VRXR.isRunning() then
        send({ ok = true, alive = true, running = false, status = VRXR.status() })
      else
        local time, should = VRXR.waitFrame()
        local views, input
        if time then
          heldTime = time
          input = plain(VRXR.input(time))
          if should then views = plain(VRXR.locateViews(time)) end
        end
        send({
          ok = true, alive = true, running = true,
          should = should and true or false,
          haveTime = time ~= nil,
          views = views, input = input,
          status = VRXR.status(),
        })
      end
    elseif msg.op == "submit" then
      if heldTime then
        local function upload(src, acquire, release)
          if not (src and src.bytes) then return end
          local tex, tw, th = acquire()
          if not tex then return end
          VRGL.uploadRGBA(tex, src.dw or tw, src.dh or th, src.bytes,
                          src.sw or src.w, src.sh or src.h,
                          src.sx or 0, src.sy or 0,
                          src.rw or src.w, src.rh or src.h)
          release()
        end
        upload(msg.eye1, function() return VRXR.acquireEye(1) end,
               function() VRXR.releaseEye(1) end)
        upload(msg.eye2, function() return VRXR.acquireEye(2) end,
               function() VRXR.releaseEye(2) end)
        upload(msg.quad, function() return VRXR.acquireQuad() end,
               function() VRXR.releaseQuad() end)
        VRXR.endFrame(heldTime, msg.world and true or nil, msg.quadPose)
        heldTime = nil
      end
      send({ ok = true })
    else
      send({ ok = true })
    end
  end

  VRXR.stop()
  VRGL.releaseContext()
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
  pcall(function() if VRXR and VRXR.stop then VRXR.stop() end end)
  pcall(function() if VRGL and VRGL.releaseContext then VRGL.releaseContext() end end)
  pcall(send, { ok = false, err = tostring(err) })
end
