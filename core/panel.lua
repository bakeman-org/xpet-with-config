local M = {}
local X11C = require('core.x11_const')
local Surface = require('core.surface')
local UI = require('core.ui')
local TextInput = require('core.text_input')

local Panel = {}
Panel.__index = Panel

local function keycode_of(ctx, name)
  return ctx.X11.XKeysymToKeycode(ctx.dpy, ctx.X11.XStringToKeysym(name))
end

function M.new(ctx, opts)
  opts = opts or {}
  local w, h = opts.w, opts.h
  local x = opts.x or math.floor((ctx.scr_w - w) / 2)
  local y_shown = opts.y_shown
  if y_shown == nil then
    y_shown = math.floor((ctx.scr_h - h) / 2)
  end
  local y_hidden = opts.y_hidden or -(h + 4)

  local self = setmetatable({}, Panel)
  self.ctx = ctx
  self.opts = opts
  self.x, self.w, self.h = x, w, h
  self.y_shown, self.y_hidden = y_shown, y_hidden
  self.visible = false
  self.anim_y = y_hidden
  self.target_y = y_hidden
  self.kbd_grabbed = false

  self.canvas = ctx.create_canvas(w, h, {
    x = x,
    y = y_hidden,
    bg = opts.bg or (opts.theme and opts.theme.bg),
    border = opts.border or (opts.theme and opts.theme.bg),
    border_width = opts.border_width or 1,
  })

  self.surf = Surface.new(ctx, w, h)
  self.ui = UI.new(ctx, opts.theme)
  self.ui:attach(self.surf)

  if opts.input then
    self.input = TextInput.new(ctx, opts.input)
    self.ic = ctx.xim_create_ic and ctx.xim_create_ic(self.canvas.win) or nil
    self._code_space = keycode_of(ctx, 'space')
  end
  if opts.open_key then
    self._code_open = keycode_of(ctx, opts.open_key)
  end

  return self
end

function Panel:show()
  self.visible = true
  if self.opts.on_show then
    self.opts.on_show(self)
  end
  self.anim_y = self.y_hidden
  self.target_y = self.y_shown
  self.canvas:move(self.x, math.floor(self.anim_y))
  self:draw()
  self.canvas:show()
end

function Panel:hide()
  self.visible = false
  self.target_y = self.y_hidden
  self:blur_input()
  if self.opts.on_hide then
    self.opts.on_hide(self)
  end
end

function Panel:toggle()
  if self.visible then
    self:hide()
  else
    self:show()
  end
end

function Panel:focus_input()
  if not self.input then
    return
  end
  if not self.kbd_grabbed then
    local X, dpy = self.ctx.X11, self.ctx.dpy
    self.canvas:enable_keyboard(true)
    X.XGrabKeyboard(dpy, self.canvas.win, 0, 1, 1, 0)
    if self.ic then
      X.XSetICFocus(self.ic)
    end
    X.XFlush(dpy)
    self.kbd_grabbed = true
  end
  self.input:focus()
end

function Panel:blur_input()
  if not self.input then
    return
  end
  if self.kbd_grabbed then
    local X, dpy = self.ctx.X11, self.ctx.dpy
    if self.ic then
      X.XUnsetICFocus(self.ic)
    end
    X.XUngrabKeyboard(dpy, 0)
    self.canvas:enable_keyboard(false)
    X.XFlush(dpy)
    self.kbd_grabbed = false
  end
  self.input:blur()
end

function Panel:lookup_string(ev)
  local X = self.ctx.X11
  local ffi = self.ctx.ffi
  local buf = ffi.new('char[256]')
  local ks = ffi.new('KeySym[1]')
  local n, sym, status
  if self.ic then
    local st = ffi.new('int[1]')
    n = X.Xutf8LookupString(self.ic, ffi.cast('XKeyEvent*', ev), buf, 255, ks, st)
    status = st[0]
    sym = ks[0]
  else
    n = X.XLookupString(ffi.cast('XKeyEvent*', ev), buf, 255, ks, nil)
    status = 4
    sym = ks[0]
  end
  local text = ''
  if n > 0 and (status == 2 or status == 4) then
    text = ffi.string(buf, n)
  end
  return text, sym, status
end

function Panel:draw()
  if not self.surf then
    return
  end
  -- 重入保护：draw 内部（按钮回调）再触发 draw 时挂起，帧末补一次
  -- 否则 mrelease 未清除会导致 clicked 重复命中 -> 无限递归 stack overflow
  if self._drawing then
    self._redraw_pending = true
    return
  end
  self._drawing = true
  local s, ui = self.surf, self.ui
  s:clear(ui.theme.bg)
  ui:begin()
  if self.opts.draw then
    self.opts.draw(self)
  end
  ui:end_frame()
  s:flush(self.canvas.win, self.canvas.wgc, 0, 0)
  self._drawing = false
  if self._redraw_pending then
    self._redraw_pending = false
    self:draw()
  end
end

function Panel:on_ev(t, ev)
  if not self.visible then
    return false
  end
  local C = X11C
  local bit = self.ctx.bit

  if t == C.KEY_PRESS then
    if not self.input then
      return false
    end
    local ctrl = bit.band(ev.xkey.state, C.CONTROL_MASK) ~= 0
    local shift = bit.band(ev.xkey.state, C.SHIFT_MASK) ~= 0
    if self._code_space and ev.xkey.keycode == self._code_space and ctrl then
      os.execute('fcitx5-remote -t >/dev/null 2>&1 &')
      return true
    end
    if self.kbd_grabbed then
      local text, sym, status = self:lookup_string(ev)
      if status == 1 then
        self:draw()
        return true
      end
      if self.opts.on_key and self.opts.on_key(self, sym, ctrl, shift, text) then
        self:draw()
        return true
      end
      self.input:on_key(sym, ctrl, shift, text)
      self.input:_ensure_cursor_visible()
      self:draw()
      return true
    end
    if self.opts.on_hotkey and self.opts.on_hotkey(self, ev, nil, ctrl, shift) then
      return true
    end
    if self._code_open and ev.xkey.keycode == self._code_open then
      self:focus_input()
      self:draw()
      return true
    end
    return false
  end

  if t == C.EXPOSE then
    if ev.xexpose.window == self.canvas.win then
      self:draw()
      return true
    end
    return false
  end

  if t == C.BUTTON_PRESS or t == C.BUTTON_RELEASE then
    if ev.xbutton.window ~= self.canvas.win then
      return false
    end
  elseif t == C.MOTION_NOTIFY then
    if ev.xmotion.window ~= self.canvas.win then
      return false
    end
  else
    return false
  end

  self.ui:on_event(t, ev)

  if t == C.BUTTON_PRESS then
    local mx, my = ev.xbutton.x, ev.xbutton.y
    local btn = ev.xbutton.button
    local shift = bit.band(ev.xbutton.state, C.SHIFT_MASK) ~= 0
    if btn == C.WHEEL_UP or btn == C.WHEEL_DOWN then
      if self.opts.on_wheel then
        self.opts.on_wheel(self, btn, mx, my)
        self:draw()
        return true
      end
      return false
    end
    if self.input and self.input:on_mouse_press(mx, my, shift) then
      self:focus_input()
      self:draw()
      return true
    end
    if self.opts.on_press and self.opts.on_press(self, mx, my, btn, shift) then
      self:draw()
      return true
    end
    if self.input and self.kbd_grabbed then
      self:blur_input()
    end
    self:draw()
    return true
  end

  if t == C.BUTTON_RELEASE then
    if self.input then
      self.input:on_mouse_release()
    end
    return true
  end

  if self.input and self.input:on_mouse_move(ev.xmotion.x, ev.xmotion.y) then
    self.input:_ensure_cursor_visible()
    self:draw()
    return true
  end
  self:draw()
  return true
end

function Panel:tick(dt)
  if self.input then
    self.input:tick(dt)
  end
  if self.anim_y ~= self.target_y then
    local d = self.target_y - self.anim_y
    if math.abs(d) < 1.5 then
      self.anim_y = self.target_y
    else
      self.anim_y = self.anim_y + d * 0.3
    end
    self.canvas:move(self.x, math.floor(self.anim_y))
    if self.anim_y == self.target_y and self.target_y < 0 then
      self.canvas:hide()
      return
    end
  end
  if self.visible and self.opts.tick then
    self.opts.tick(self, dt)
  end
end

function Panel:destroy()
  self:blur_input()
  if self.ic and self.ctx.xim_destroy_ic then
    self.ctx.xim_destroy_ic(self.ic)
  end
  self.ic = nil
  if self.surf then
    self.surf:destroy()
  end
  if self.canvas then
    self.canvas:destroy()
  end
end

return M
