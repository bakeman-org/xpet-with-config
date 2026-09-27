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

-- 计算显示位置（sx,sy）与隐藏位置（hx,hy），每次 show 时重算以支持热加载
-- pos: center/top/bottom/left/right/top_left/top_right/bottom_left/bottom_right
-- anim: auto/slide_down/slide_up/slide_left/slide_right/none
function Panel:layout()
  local ctx, w, h = self.ctx, self.w, self.h
  local ui_cfg = ctx.config.ui or {}
  -- 优先级：opts.pos/anim > config[opts.name].pos/anim > config.ui > 默认
  local pcfg = self.opts.name and ctx.config[self.opts.name] or {}
  local pos = self.opts.pos or pcfg.pos or ui_cfg.pos or 'center'
  local cx = math.floor((ctx.scr_w - w) / 2)
  local cy = math.floor((ctx.scr_h - h) / 2)
  local sx, sy
  if pos == 'top' then
    sx, sy = cx, 0
  elseif pos == 'bottom' then
    sx, sy = cx, ctx.scr_h - h
  elseif pos == 'left' then
    sx, sy = 0, cy
  elseif pos == 'right' then
    sx, sy = ctx.scr_w - w, cy
  elseif pos == 'top_left' then
    sx, sy = 0, 0
  elseif pos == 'top_right' then
    sx, sy = ctx.scr_w - w, 0
  elseif pos == 'bottom_left' then
    sx, sy = 0, ctx.scr_h - h
  elseif pos == 'bottom_right' then
    sx, sy = ctx.scr_w - w, ctx.scr_h - h
  else
    sx, sy = cx, cy
  end
  sx = self.opts.x or math.max(0, sx)
  sy = self.opts.y_shown or math.max(0, sy)
  if sx > ctx.scr_w - w then
    sx = math.max(0, ctx.scr_w - w)
  end
  if sy > ctx.scr_h - h then
    sy = math.max(0, ctx.scr_h - h)
  end

  local anim = self.opts.anim or pcfg.anim or ui_cfg.anim or 'auto'
  if anim == 'auto' then
    anim = (pos == 'bottom' or pos == 'bottom_left' or pos == 'bottom_right')
      and 'slide_up' or 'slide_down'
  end
  local hx, hy = sx, sy
  if anim == 'slide_down' then
    hy = -h - 4
  elseif anim == 'slide_up' then
    hy = ctx.scr_h + 4
  elseif anim == 'slide_left' then
    hx = ctx.scr_w + 4
  elseif anim == 'slide_right' then
    hx = -w - 4
  end
  self.anim_kind = anim
  self.sx, self.sy, self.hx, self.hy = sx, sy, hx, hy
end

function M.new(ctx, opts)
  opts = opts or {}
  local w, h = opts.w, opts.h

  local self = setmetatable({}, Panel)
  self.ctx = ctx
  self.opts = opts
  self.w, self.h = w, h
  self.visible = false
  self.kbd_grabbed = false
  self:layout()
  self.anim_x, self.anim_y = self.sx, self.sy
  self.target_x, self.target_y = self.sx, self.sy

  self.canvas = ctx.create_canvas(w, h, {
    x = self.sx,
    y = self.sy,
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
  self:layout()
  self.visible = true
  if self.opts.on_show then
    self.opts.on_show(self)
  end
  if self.anim_kind == 'none' then
    self.anim_x, self.anim_y = self.sx, self.sy
    self.target_x, self.target_y = self.sx, self.sy
    self.canvas:move(self.sx, self.sy)
  else
    self.anim_x, self.anim_y = self.hx, self.hy
    self.target_x, self.target_y = self.sx, self.sy
    self.canvas:move(self.hx, self.hy)
  end
  self:draw()
  self.canvas:show()
end

function Panel:hide()
  self.visible = false
  self:blur_input()
  if self.opts.on_hide then
    self.opts.on_hide(self)
  end
  if self.anim_kind == 'none' then
    self.canvas:hide()
  else
    self.target_x, self.target_y = self.hx, self.hy
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
      if self.opts.on_key and self.opts.on_key(self, sym, ctrl, shift, text, ev.xkey.state) then
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
  if self.anim_x ~= self.target_x or self.anim_y ~= self.target_y then
    local k = 1 - math.exp(-dt / 60)
    local dx = self.target_x - self.anim_x
    local dy = self.target_y - self.anim_y
    if math.abs(dx) < 1.5 then
      self.anim_x = self.target_x
    else
      self.anim_x = self.anim_x + dx * k
    end
    if math.abs(dy) < 1.5 then
      self.anim_y = self.target_y
    else
      self.anim_y = self.anim_y + dy * k
    end
    self.canvas:move(math.floor(self.anim_x), math.floor(self.anim_y))
    if self.anim_x == self.target_x and self.anim_y == self.target_y
      and not self.visible then
      -- 滑出到隐藏位完成，收起窗口
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
