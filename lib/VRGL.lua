-- VR: the raw OpenGL this mod is otherwise proud to never need.
--
-- OpenXR hands over its swapchain images as GL TEXTURE IDS, and LOVE never
-- exposes the GL names behind its own canvases -- so getting a rendered
-- eye from a love Canvas into a headset means dropping below LOVE for a
-- few calls a frame: discover the canvas's framebuffer, blit it into the
-- swapchain texture, and put the pipeline back exactly as LOVE believes it
-- to be. Everything here is that, and only that.
--
-- Three rules keep this safe:
--
--   discovery over spelunking. The canvas's FBO id is read from the
--   driver with documented queries (bind the canvas THROUGH LOVE, ask
--   GL_DRAW_FRAMEBUFFER_BINDING) rather than from LOVE's internals, so a
--   LOVE patch cannot move it out from under us.
--
--   restore what LOVE caches. LOVE tracks the bound framebuffer and skips
--   redundant binds, so raw binds must end back at the exact binding LOVE
--   thinks is current -- the default framebuffer, 0, since every call
--   here runs between LOVE passes -- or LOVE's next draw lands in ours.
--
--   pcall at the rim, ffi inside. The FFI setup can fail (headless, a GL
--   context without FBO entry points); it fails ONCE, at load(), and
--   callers see `nil, reason` rather than an error mid-frame.

local VRGL = {}

local ffi = nil
local gl = nil                -- opengl32 exports (GL 1.1 + wgl)
local ext = {}                -- post-1.1 entry points via wglGetProcAddress
local ready = false
local reason = nil
local fbo = nil               -- our scratch framebuffer, made once
local uploadTex, uploadFbo, uploadW, uploadH = nil, nil, 0, 0

local GL = {
  FRAMEBUFFER = 0x8D40,
  READ_FRAMEBUFFER = 0x8CA8,
  DRAW_FRAMEBUFFER = 0x8CA9,
  DRAW_FRAMEBUFFER_BINDING = 0x8CA6,
  COLOR_ATTACHMENT0 = 0x8CE0,
  COLOR_BUFFER_BIT = 0x4000,
  NEAREST = 0x2600,
  LINEAR = 0x2601,
  TEXTURE_2D = 0x0DE1,
  RGBA = 0x1908,
  UNSIGNED_BYTE = 0x1401,
  RGBA8 = 0x8058,
  TEXTURE_MIN_FILTER = 0x2801,
  TEXTURE_MAG_FILTER = 0x2800,
  UNPACK_ALIGNMENT = 0x0CF5,
  UNPACK_ROW_LENGTH = 0x0CF2,
  UNPACK_SKIP_ROWS = 0x0CF3,
  UNPACK_SKIP_PIXELS = 0x0CF4,
  FRONT = 0x0404,
  BACK = 0x0405,
}
VRGL.GL = GL

local CDEF = [[
typedef void (__stdcall *PROC)();
void* wglGetCurrentDC(void);
void* wglGetCurrentContext(void);
PROC wglGetProcAddress(const char*);
unsigned int glGetError(void);
void glGetIntegerv(unsigned int pname, int* params);
void glReadBuffer(unsigned int mode);
void glFlush(void);
void glFinish(void);
void glCopyTexSubImage2D(unsigned int target, int level, int xoffset,
                         int yoffset, int x, int y, int width, int height);
void glBindTexture(unsigned int target, unsigned int texture);
void glGenTextures(int n, unsigned int* textures);
void glDeleteTextures(int n, const unsigned int* textures);
void glTexImage2D(unsigned int target, int level, int internalformat,
                  int width, int height, int border, unsigned int format,
                  unsigned int type, const void* data);
void glTexSubImage2D(unsigned int target, int level, int xoffset, int yoffset,
                     int width, int height, unsigned int format,
                     unsigned int type, const void* data);
void glTexParameteri(unsigned int target, unsigned int pname, int param);
void glPixelStorei(unsigned int pname, int param);
void* wglCreateContext(void* hdc);
int wglMakeCurrent(void* hdc, void* hglrc);
int wglDeleteContext(void* hglrc);
typedef void* (__stdcall *WGL_PROC)(void);
typedef void* (__stdcall *pfn_wglCreateContextAttribsARB)(void* hdc, void* share,
                                                          const int* attribs);
typedef void (__stdcall *pfn_glBindFramebuffer)(unsigned int, unsigned int);
typedef void (__stdcall *pfn_glGenFramebuffers)(int, unsigned int*);
typedef void (__stdcall *pfn_glDeleteFramebuffers)(int, const unsigned int*);
typedef void (__stdcall *pfn_glFramebufferTexture2D)(unsigned int,
    unsigned int, unsigned int, unsigned int, int);
typedef void (__stdcall *pfn_glBlitFramebuffer)(int, int, int, int,
    int, int, int, int, unsigned int, unsigned int);
]]

-- One-time FFI setup. Idempotent, and every path out records why it
-- stopped, so VR's status line can say something better than "no".
function VRGL.load()
  if ready then return true end
  if reason then return false, reason end
  local ok, err = pcall(function()
    ffi = require("ffi")
    -- cdef survives a reload; redefinition is the only error worth eating
    pcall(ffi.cdef, CDEF)
    gl = ffi.load("opengl32")
    -- The worker thread has no LOVE context. OpenXR only needs some
    -- current context on the thread that creates the session.
    if gl.wglGetCurrentContext() == nil then
      if not VRGL.ensureContext() then error(VRGL.status(), 0) end
    end
    local function proc(name, typ)
      local p = gl.wglGetProcAddress(name)
      if p == nil then error(name .. " not exposed by this GL context", 0) end
      return ffi.cast(typ, p)
    end
    ext.glBindFramebuffer = proc("glBindFramebuffer", "pfn_glBindFramebuffer")
    ext.glGenFramebuffers = proc("glGenFramebuffers", "pfn_glGenFramebuffers")
    ext.glDeleteFramebuffers =
      proc("glDeleteFramebuffers", "pfn_glDeleteFramebuffers")
    ext.glFramebufferTexture2D =
      proc("glFramebufferTexture2D", "pfn_glFramebufferTexture2D")
    ext.glBlitFramebuffer = proc("glBlitFramebuffer", "pfn_glBlitFramebuffer")
  end)
  if not ok then
    reason = "GL interop unavailable: " .. tostring(err)
    return false, reason
  end
  ready = true
  return true
end

-- A dedicated GL context for the worker thread. The game thread's context
-- belongs to LOVE and this module cannot bind it from a sandbox that
-- refuses FFI there. OpenXR only requires SOME current GL context on the
-- thread that creates the session, so the worker makes its own.
local hidden = nil

local WIN_CDEF = [[
typedef intptr_t (__stdcall *WNDPROC)(void*, unsigned int, uintptr_t, intptr_t);
typedef struct {
  unsigned int style;
  WNDPROC lpfnWndProc;
  int cbClsExtra;
  int cbWndExtra;
  void* hInstance;
  void* hIcon;
  void* hCursor;
  void* hbrBackground;
  const char* lpszMenuName;
  const char* lpszClassName;
} WNDCLASSA;
typedef struct {
  unsigned short nSize;
  unsigned short nVersion;
  unsigned int dwFlags;
  unsigned char iPixelType;
  unsigned char cColorBits;
  unsigned char cRedBits;
  unsigned char cRedShift;
  unsigned char cGreenBits;
  unsigned char cGreenShift;
  unsigned char cBlueBits;
  unsigned char cBlueShift;
  unsigned char cAlphaBits;
  unsigned char cAlphaShift;
  unsigned char cAccumBits;
  unsigned char cAccumRedBits;
  unsigned char cAccumGreenBits;
  unsigned char cAccumBlueBits;
  unsigned char cAccumAlphaBits;
  unsigned char cDepthBits;
  unsigned char cStencilBits;
  unsigned char cAuxBuffers;
  unsigned char iLayerType;
  unsigned char bReserved;
  unsigned int dwLayerMask;
  unsigned int dwVisibleMask;
  unsigned int dwDamageMask;
} PIXELFORMATDESCRIPTOR;
void* __stdcall GetModuleHandleA(const char*);
unsigned short __stdcall RegisterClassA(const WNDCLASSA*);
void* __stdcall CreateWindowExA(unsigned int, const char*, const char*,
  unsigned int, int, int, int, int, void*, void*, void*, void*);
int __stdcall DestroyWindow(void*);
void* __stdcall GetDC(void*);
int __stdcall ReleaseDC(void*, void*);
int __stdcall ChoosePixelFormat(void*, const PIXELFORMATDESCRIPTOR*);
int __stdcall SetPixelFormat(void*, int, const PIXELFORMATDESCRIPTOR*);
intptr_t __stdcall DefWindowProcA(void*, unsigned int, uintptr_t, intptr_t);
]]

function VRGL.ensureContext()
  if hidden and hidden.hglrc then return true end
  local ok, err = pcall(function()
    ffi = ffi or require("ffi")
    pcall(ffi.cdef, CDEF)
    pcall(ffi.cdef, WIN_CDEF)
    gl = gl or ffi.load("opengl32")
    if gl.wglGetCurrentContext() ~= nil then return end
    local user = ffi.load("user32")
    local gdi = ffi.load("gdi32")
    local proc = ffi.cast("WNDPROC", user.DefWindowProcA)
    -- Anchor the callback and the class name before anything else can
    -- collect them: the window keeps both, and a WNDCLASSA field does not.
    local className = ffi.new("char[16]", "VoxelVRGL")
    hidden = { proc = proc, className = className, user = user, gdi = gdi }
    local wc = ffi.new("WNDCLASSA")
    wc.style = 0x0020 -- CS_OWNDC
    wc.lpfnWndProc = proc
    wc.hInstance = user.GetModuleHandleA(nil)
    wc.lpszClassName = className
    if user.RegisterClassA(wc) == 0 then
      -- the class stays registered for the life of the process; a second
      -- session reuses it and CreateWindow is the real check
    end
    local hwnd = user.CreateWindowExA(0, "VoxelVRGL", "VoxelVR",
      0, 0, 0, 1, 1, nil, nil, wc.hInstance, nil)
    if hwnd == nil then error("CreateWindowExA failed", 0) end
    hidden.hwnd = hwnd
    local hdc = gdi.GetDC(hwnd)
    if hdc == nil then error("GetDC failed", 0) end
    hidden.hdc = hdc
    local pfd = ffi.new("PIXELFORMATDESCRIPTOR")
    pfd.nSize = ffi.sizeof("PIXELFORMATDESCRIPTOR")
    pfd.nVersion = 1
    pfd.dwFlags = 0x25 -- DRAW_TO_WINDOW | SUPPORT_OPENGL | DOUBLEBUFFER
    pfd.cColorBits = 32
    pfd.cDepthBits = 24
    local pf = gdi.ChoosePixelFormat(hdc, pfd)
    if pf == 0 or gdi.SetPixelFormat(hdc, pf, pfd) == 0 then
      error("SetPixelFormat failed", 0)
    end
    local legacy = gl.wglCreateContext(hdc)
    if legacy == nil or gl.wglMakeCurrent(hdc, legacy) == 0 then
      error("wglCreateContext failed", 0)
    end
    local hglrc = legacy
    local createPtr = gl.wglGetProcAddress("wglCreateContextAttribsARB")
    if createPtr ~= nil then
      local create = ffi.cast("pfn_wglCreateContextAttribsARB", createPtr)
      local attribs = ffi.new("int[7]", 0x2091, 4, 0x2092, 5, 0x9126, 2, 0)
      local modern = create(hdc, nil, attribs)
      if modern ~= nil and gl.wglMakeCurrent(hdc, modern) ~= 0 then
        gl.wglDeleteContext(legacy)
        hglrc = modern
      end
      hidden.create = create
      hidden.attribs = attribs
    end
    hidden.hwnd, hidden.hdc, hidden.hglrc = hwnd, hdc, hglrc
    hidden.wc = wc
  end)
  if not ok then
    reason = "GL context unavailable: " .. tostring(err)
    if hidden and not hidden.hglrc then VRGL.releaseContext() end
    return false
  end
  if gl.wglGetCurrentContext() == nil then
    reason = "GL context unavailable: context is not current"
    if hidden and not hidden.hglrc then VRGL.releaseContext() end
    return false
  end
  return true
end

function VRGL.releaseContext()
  local h = hidden
  hidden = nil
  if not h then return end
  pcall(function()
    if gl then gl.wglMakeCurrent(nil, nil) end
    if h.hglrc and gl then gl.wglDeleteContext(h.hglrc) end
    if h.hdc and h.hwnd and h.gdi then h.gdi.ReleaseDC(h.hwnd, h.hdc) end
    if h.hwnd and h.user then h.user.DestroyWindow(h.hwnd) end
  end)
end

-- The window's device and GL contexts, which the OpenXR session binds to.
function VRGL.contexts()
  if not VRGL.load() then return nil, nil end
  return gl.wglGetCurrentDC(), gl.wglGetCurrentContext()
end

-- The GL framebuffer behind a LOVE canvas. Bound through LOVE (so LOVE's
-- own cache stays truthful), read from the driver, then released.
function VRGL.canvasFBO(canvas)
  if not VRGL.load() then return nil end
  local id = nil
  local ok = pcall(function()
    love.graphics.setCanvas(canvas)
    local out = ffi.new("int[1]")
    gl.glGetIntegerv(GL.DRAW_FRAMEBUFFER_BINDING, out)
    id = out[0]
    love.graphics.setCanvas()
  end)
  pcall(love.graphics.setCanvas)
  return ok and id or nil
end

-- Put an RGBA8 top-down buffer (a LOVE ImageData string) into a GL texture
-- on THIS thread's context. Row 0 is the visual top; OpenGL stores that row
-- at y = 0, matching the canvas blit above (visual top at the bottom of the
-- GL image). A size mismatch is scaled. Unpack state is restored either way.
function VRGL.uploadRGBA(dstTex, dstW, dstH, bytes, srcW, srcH, sx, sy, rw, rh)
  if not (ready and type(bytes) == "string" and dstTex) then return false end
  sx, sy = sx or 0, sy or 0
  rw, rh = rw or srcW, rh or srcH
  dstW, dstH = dstW or rw, dstH or rh
  if rw < 1 or rh < 1 or dstW < 1 or dstH < 1 then return false end
  local ok = pcall(function()
    local function resetUnpack()
      gl.glPixelStorei(GL.UNPACK_ROW_LENGTH, 0)
      gl.glPixelStorei(GL.UNPACK_SKIP_PIXELS, 0)
      gl.glPixelStorei(GL.UNPACK_SKIP_ROWS, 0)
      gl.glPixelStorei(GL.UNPACK_ALIGNMENT, 4)
    end
    gl.glPixelStorei(GL.UNPACK_ALIGNMENT, 1)
    gl.glPixelStorei(GL.UNPACK_ROW_LENGTH, srcW)
    gl.glPixelStorei(GL.UNPACK_SKIP_PIXELS, sx)
    gl.glPixelStorei(GL.UNPACK_SKIP_ROWS, sy)
    local ptr = ffi.cast("const uint8_t*", bytes)
    if rw == dstW and rh == dstH then
      gl.glBindTexture(GL.TEXTURE_2D, dstTex)
      gl.glTexSubImage2D(GL.TEXTURE_2D, 0, 0, 0, rw, rh,
                         GL.RGBA, GL.UNSIGNED_BYTE, ptr)
      gl.glBindTexture(GL.TEXTURE_2D, 0)
      gl.glFinish()
      resetUnpack()
      return
    end
    if not (uploadTex and uploadW == rw and uploadH == rh) then
      if not uploadTex then
        local out = ffi.new("unsigned int[1]")
        gl.glGenTextures(1, out)
        uploadTex = out[0]
      end
      gl.glBindTexture(GL.TEXTURE_2D, uploadTex)
      gl.glTexParameteri(GL.TEXTURE_2D, GL.TEXTURE_MIN_FILTER, GL.LINEAR)
      gl.glTexParameteri(GL.TEXTURE_2D, GL.TEXTURE_MAG_FILTER, GL.LINEAR)
      gl.glTexImage2D(GL.TEXTURE_2D, 0, GL.RGBA, rw, rh, 0,
                      GL.RGBA, GL.UNSIGNED_BYTE, ptr)
      uploadW, uploadH = rw, rh
    else
      gl.glBindTexture(GL.TEXTURE_2D, uploadTex)
      gl.glTexSubImage2D(GL.TEXTURE_2D, 0, 0, 0, rw, rh,
                         GL.RGBA, GL.UNSIGNED_BYTE, ptr)
    end
    gl.glBindTexture(GL.TEXTURE_2D, 0)
    resetUnpack()
    if not uploadFbo then
      local out = ffi.new("unsigned int[1]")
      ext.glGenFramebuffers(1, out)
      uploadFbo = out[0]
    end
    if not fbo then
      local out = ffi.new("unsigned int[1]")
      ext.glGenFramebuffers(1, out)
      fbo = out[0]
    end
    ext.glBindFramebuffer(GL.READ_FRAMEBUFFER, uploadFbo)
    ext.glFramebufferTexture2D(GL.READ_FRAMEBUFFER, GL.COLOR_ATTACHMENT0,
                               GL.TEXTURE_2D, uploadTex, 0)
    ext.glBindFramebuffer(GL.DRAW_FRAMEBUFFER, fbo)
    ext.glFramebufferTexture2D(GL.DRAW_FRAMEBUFFER, GL.COLOR_ATTACHMENT0,
                               GL.TEXTURE_2D, dstTex, 0)
    ext.glBlitFramebuffer(0, 0, rw, rh, 0, 0, dstW, dstH,
                          GL.COLOR_BUFFER_BIT, GL.LINEAR)
    ext.glBindFramebuffer(GL.FRAMEBUFFER, 0)
    gl.glFinish()
  end)
  if not ok then
    pcall(function()
      if ext.glBindFramebuffer then ext.glBindFramebuffer(GL.FRAMEBUFFER, 0) end
      if gl then
        gl.glBindTexture(GL.TEXTURE_2D, 0)
        gl.glPixelStorei(GL.UNPACK_ROW_LENGTH, 0)
        gl.glPixelStorei(GL.UNPACK_SKIP_PIXELS, 0)
        gl.glPixelStorei(GL.UNPACK_SKIP_ROWS, 0)
        gl.glPixelStorei(GL.UNPACK_ALIGNMENT, 4)
      end
    end)
  end
  return ok
end

-- Blit a LOVE canvas's pixels into a GL texture (an XR swapchain image),
-- flipped vertically on the way: LOVE renders its canvases y-down, GL
-- textures composite y-up, and the blit is the one place the two meet.
--
-- `srcFBO` comes from canvasFBO (cache it -- it is stable for the
-- canvas's lifetime). Ends with framebuffer 0 bound, which is the binding
-- LOVE believes in between its passes.
function VRGL.blitToTexture(srcFBO, sw, sh, tex, tw, th)
  if not ready then return false end
  local ok = pcall(function()
    if not fbo then
      local out = ffi.new("unsigned int[1]")
      ext.glGenFramebuffers(1, out)
      fbo = out[0]
    end
    ext.glBindFramebuffer(GL.DRAW_FRAMEBUFFER, fbo)
    ext.glFramebufferTexture2D(GL.DRAW_FRAMEBUFFER, GL.COLOR_ATTACHMENT0,
                               GL.TEXTURE_2D, tex, 0)
    ext.glBindFramebuffer(GL.READ_FRAMEBUFFER, srcFBO)
    ext.glBlitFramebuffer(0, sh, sw, 0, 0, 0, tw, th,
                          GL.COLOR_BUFFER_BIT, GL.LINEAR)
    ext.glBindFramebuffer(GL.FRAMEBUFFER, 0)
  end)
  if not ok then pcall(function() ext.glBindFramebuffer(GL.FRAMEBUFFER, 0) end) end
  return ok
end

-- Copy the WINDOW's currently displayed image (the front buffer -- the
-- back buffer's contents are undefined after a swap) into a GL texture:
-- the UI quad the headset floats in front of the world. Restores the read
-- buffer to BACK, the default LOVE never changes.
function VRGL.copyFrontBuffer(tex, w, h)
  if not ready then return false end
  local ok = pcall(function()
    ext.glBindFramebuffer(GL.FRAMEBUFFER, 0)
    gl.glReadBuffer(GL.FRONT)
    gl.glBindTexture(GL.TEXTURE_2D, tex)
    gl.glCopyTexSubImage2D(GL.TEXTURE_2D, 0, 0, 0, 0, 0, w, h)
    gl.glBindTexture(GL.TEXTURE_2D, 0)
    gl.glReadBuffer(GL.BACK)
  end)
  if not ok then pcall(function() gl.glReadBuffer(GL.BACK) end) end
  return ok
end

-- Blit a REGION of the window's front buffer into a GL texture (an XR
-- swapchain image), SCALED to (dw, dh) at the texture's origin. This is
-- the panel's route: the whole-window copy above is pixel-for-pixel, so
-- a window larger than the swapchain image simply ran off its edges --
-- fullscreen cut the GB frame's own menu off the panel. A scaled blit
-- has no such cliff: the letterbox region lands whole at the texture's
-- own resolution whatever size the window is. Source coordinates are GL
-- window space, origin bottom-left; LINEAR, because the region rarely
-- matches the target size exactly and dropped rows read worse than a
-- soft one. Restores the read buffer and framebuffer LOVE believes in.
function VRGL.copyFrontRegionToTexture(tex, sx, sy, sw, sh, dw, dh)
  if not ready then return false end
  local ok = pcall(function()
    if not fbo then
      local out = ffi.new("unsigned int[1]")
      ext.glGenFramebuffers(1, out)
      fbo = out[0]
    end
    ext.glBindFramebuffer(GL.READ_FRAMEBUFFER, 0)
    gl.glReadBuffer(GL.FRONT)
    ext.glBindFramebuffer(GL.DRAW_FRAMEBUFFER, fbo)
    ext.glFramebufferTexture2D(GL.DRAW_FRAMEBUFFER, GL.COLOR_ATTACHMENT0,
                               GL.TEXTURE_2D, tex, 0)
    ext.glBlitFramebuffer(sx, sy, sx + sw, sy + sh, 0, 0, dw, dh,
                          GL.COLOR_BUFFER_BIT, GL.LINEAR)
    ext.glBindFramebuffer(GL.FRAMEBUFFER, 0)
    gl.glReadBuffer(GL.BACK)
  end)
  if not ok then
    pcall(function()
      ext.glBindFramebuffer(GL.FRAMEBUFFER, 0)
      gl.glReadBuffer(GL.BACK)
    end)
  end
  return ok
end

-- Copy the window's front buffer into a LOVE CANVAS (by its FBO id, from
-- canvasFBO), flipped so the canvas reads top-down exactly like the
-- window: what LOVE then draws from that canvas at (0,0) is the screen,
-- row for row. The battle's VR quad is the caller: it needs the screen as
-- something LOVE can CUT UP (scissored cutouts of the UI), not just as a
-- finished texture -- copyFrontBuffer above is for the finished case.
function VRGL.copyFrontToCanvas(dstFBO, w, h)
  if not ready then return false end
  local ok = pcall(function()
    ext.glBindFramebuffer(GL.READ_FRAMEBUFFER, 0)
    gl.glReadBuffer(GL.FRONT)
    ext.glBindFramebuffer(GL.DRAW_FRAMEBUFFER, dstFBO)
    ext.glBlitFramebuffer(0, 0, w, h, 0, h, w, 0,
                          GL.COLOR_BUFFER_BIT, GL.NEAREST)
    ext.glBindFramebuffer(GL.FRAMEBUFFER, 0)
    gl.glReadBuffer(GL.BACK)
  end)
  if not ok then
    pcall(function()
      ext.glBindFramebuffer(GL.FRAMEBUFFER, 0)
      gl.glReadBuffer(GL.BACK)
    end)
  end
  return ok
end

function VRGL.status()
  if ready then return "ok" end
  return reason or "not loaded"
end

return VRGL
