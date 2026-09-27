local M = {}

function M.open(ffi_init)
  local X11 = ffi_init.X11
  local ffi = ffi_init.ffi

  local dpy = X11.XOpenDisplay(nil)
  if dpy == nil then
    error('cannot open X display')
  end
  local screen = X11.XDefaultScreen(dpy)
  local root = X11.XRootWindow(dpy, screen)
  local depth = X11.XDefaultDepth(dpy, screen)
  local black = X11.XBlackPixel(dpy, screen)
  local white = X11.XWhitePixel(dpy, screen)
  local scr_w = X11.XDisplayWidth(dpy, screen)
  local scr_h = X11.XDisplayHeight(dpy, screen)

  local err_handler = ffi.cast('int (*)(Display*, XErrorEvent*)', function(_, e)
    -- 忽略 keybind 被别的客户端抢占产生的 BadAccess
    -- if e.error_code == 10 and e.request_code == 33 then
    --   return 0
    -- end
    io.stderr:write(
      string.format(
        '[xpet] X error: code=%d req=%d.%d resource=0x%x\n',
        e.error_code,
        e.request_code,
        e.minor_code,
        e.resourceid
      )
    )
    return 0
  end)
  X11.XSetErrorHandler(err_handler)
  M.err_handler = err_handler -- 引用保活，防止 FFI 回调被 GC 成野指针
  return {
    dpy = dpy,
    screen = screen,
    root = root,
    depth = depth,
    black = black,
    white = white,
    scr_w = scr_w,
    scr_h = scr_h,
  }
end

return M
