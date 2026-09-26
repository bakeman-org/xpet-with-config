local M = {}
local ffi = require('ffi')
local X11C = require('core.x11_const')

function M.new(ctx, w, h, opts)
  opts = opts or {}
  local bg = opts.bg or 0x1a1b26
  local border = opts.border or bg
  local border_w = opts.border_width or 1
  local init_x = opts.x or math.floor(ctx.scr_w / 2 - w / 2)
  local init_y = opts.y or math.floor(ctx.scr_h / 2 - h / 2)

  local X11 = ctx.X11
  local dpy = ctx.dpy

  ---@class MyX11Attrs : ffi.cdata*
  ---@field override_redirect integer
  ---@field background_pixel integer
  ---@field border_pixel integer
  local attrs = ffi.new('XSetWindowAttributes')
  attrs.override_redirect = 1
  attrs.background_pixel = bg
  attrs.border_pixel = border

  local mask = X11C.CW_OVERRIDE_REDIRECT + X11C.CW_BACK_PIXEL + X11C.CW_BORDER_PIXEL

  local win = X11.XCreateWindow(
    dpy,
    ctx.root,
    init_x,
    init_y,
    w,
    h,
    border_w,
    ctx.depth,
    1,
    nil,
    mask,
    attrs
  )

  X11.XSelectInput(dpy, win, X11C.INPUT_MASK_BASE)

  local wgc = X11.XCreateGC(dpy, win, 0, nil)

  local canvas = {
    win = win,
    w = w,
    h = h,
    wgc = wgc,
    bg = bg,
    visible = false,
  }

  function canvas.show()
    X11.XMapWindow(dpy, win)
    X11.XRaiseWindow(dpy, win)
    X11.XFlush(dpy)
    canvas.visible = true
  end

  function canvas.hide()
    X11.XUnmapWindow(dpy, win)
    X11.XFlush(dpy)
    canvas.visible = false
  end

  function canvas.move(self, nx, ny)
    X11.XMoveWindow(dpy, win, nx, ny)
  end

  function canvas.resize(self, nw, nh)
    X11.XResizeWindow(dpy, win, nw, nh)
  end

  function canvas.destroy()
    X11.XFreeGC(dpy, wgc)
    X11.XDestroyWindow(dpy, win)
  end

  function canvas.enable_keyboard(enable)
    local base = X11C.INPUT_MASK_BASE
    if enable then
      base = base + X11C.KEY_PRESS_MASK + X11C.KEY_RELEASE_MASK
    end
    X11.XSelectInput(dpy, win, base)
  end

  return canvas
end

return M
