local SCRIPT_DIR = (arg[0] or 'xpet.lua'):match('^(.*)/[^/]*$') or '.'
if SCRIPT_DIR == '' then
  SCRIPT_DIR = '.'
end
package.path = SCRIPT_DIR .. '/?.lua;' .. package.path
package.cpath = SCRIPT_DIR .. '/?.so;' .. package.cpath

local ffi_init = require('core.ffi_init')(SCRIPT_DIR)
local x11_helpers = require('core.x11_helpers')
local canvas_mod = require('core.canvas')
local pet_mod = require('core.pet')
local plugin_mgr = require('core.plugin_mgr')
local config_mod = require('core.config')
local keybinds_mod = require('core.keybinds')
local Util = require('core.util')

local ffi = ffi_init.ffi
local bit = ffi_init.bit
local X11 = ffi_init.X11
local FT = ffi_init.FT
local AUD = ffi_init.AUD
local libc = ffi_init.libc

local log = Util.logger('xpet')

local CONFIG_PATH = (arg[1] and arg[1] ~= '') and config_mod.resolve_path(arg[1], SCRIPT_DIR)
  or (SCRIPT_DIR .. '/config.lua')
if not config_mod.file_exists(CONFIG_PATH) then
  error('config not found: ' .. CONFIG_PATH)
end

local load_config = function()
  return config_mod.load(CONFIG_PATH, SCRIPT_DIR)
end

local config = load_config()
log('config: %s', CONFIG_PATH)

local d = x11_helpers.open(ffi_init)
log('X11: %dx%d depth=%d', d.scr_w, d.scr_h, d.depth)

if FT.xft_init() ~= 0 then
  error('FreeType init failed')
end

local function load_font(cfg)
  local fb = table.concat(cfg.fallback_font_paths or {}, '\n')
  return FT.xft_load(cfg.font_path, cfg.font_size or 24, #fb > 0 and fb or nil)
end

local ft_ctx = load_font(config)
if ft_ctx == nil then
  error('font load failed: ' .. tostring(config.font_path))
end
log('font: %s @ %d', config.font_path, config.font_size or 24)

local xmod = os.getenv('XMODIFIERS')
if not xmod or xmod == '' then
  log('*** WARNING: XMODIFIERS is not set. ***')
  log('    Under Wayland/XWayland you MUST run:')
  log('        XMODIFIERS=@im=fcitx5 luajit xpet.lua')
  log('    (or @im=ibus if you use ibus). Otherwise XOpenIM will')
  log('    connect to nothing and Ctrl+Space will never reach the IME.')
else
  log('XMODIFIERS=%s', xmod)
end

-- ─── XIM 输入法 ─────────────────────────────────────────
local XIM_PREEDIT_NOTHING = 0x0008
local XIM_STATUS_NOTHING = 0x0400
local XIM_STYLE = bit.bor(XIM_PREEDIT_NOTHING, XIM_STATUS_NOTHING)

local xim = X11.XOpenIM(d.dpy, nil, nil, nil)
if xim == nil then
  log('XOpenIM failed: IME disabled (only ASCII input).')
  log('Check: is fcitx5/ibus running? Is XMODIFIERS set?')
  log('       Under Wayland, does fcitx5 have the XIM addon enabled?')
else
  log('XIM opened OK (style=PreeditNothing|StatusNothing)')
end

local listeners = {}
local actions = {}

local ctx = {
  SCRIPT_DIR = SCRIPT_DIR,
  ffi = ffi,
  bit = bit,
  X11 = X11,
  Xext = ffi_init.Xext,
  Xpm = ffi_init.Xpm,
  FT = FT,
  AUD = AUD,
  libc = libc,
  config = config,
  config_path = CONFIG_PATH,
  dpy = d.dpy,
  screen = d.screen,
  root = d.root,
  depth = d.depth,
  black = d.black,
  white = d.white,
  scr_w = d.scr_w,
  scr_h = d.scr_h,
  ft_ctx = ft_ctx,
  log = log,
  actions = actions,
  xim = xim,
}

function ctx.on(event, fn)
  listeners[event] = listeners[event] or {}
  listeners[event][#listeners[event] + 1] = fn
end

function ctx.emit(event, ...)
  local ls = listeners[event]
  if not ls then
    return false
  end
  local consumed = false
  for _, fn in ipairs(ls) do
    local ok, res = pcall(fn, ...)
    if not ok then
      log('listener error [%s]: %s', event, tostring(res))
    elseif res == true then
      consumed = true
    end
  end
  return consumed
end

function ctx.register_action(name, fn)
  actions[name] = fn
end

function ctx.get_text_size(text)
  local w = ffi.new('int[1]')
  local h = ffi.new('int[1]')
  FT.xft_text_extent(ft_ctx, text, w, h)
  return w[0], h[0]
end

function ctx.get_line_height()
  return FT.xft_line_height(ft_ctx)
end
function ctx.get_primary_line_height()
  return FT.xft_primary_line_height(ft_ctx)
end

function ctx.create_canvas(w, h, opts)
  return canvas_mod.new(ctx, w, h, opts)
end

function ctx.xim_create_ic(win)
  if not xim then
    return nil
  end
  local ic = X11.XCreateIC(
    xim,
    'inputStyle',
    ffi.cast('unsigned long', XIM_STYLE),
    'clientWindow',
    ffi.cast('unsigned long', win),
    'focusWindow',
    ffi.cast('unsigned long', win),
    nil
  )
  if ic == nil then
    log('XCreateIC failed for win=%d', tonumber(win))
  end
  return ic
end

function ctx.xim_destroy_ic(ic)
  if ic and xim then
    X11.XDestroyIC(ic)
  end
end

if AUD then
  local rc = AUD.audio_init()
  if rc ~= 0 then
    log('audio_init failed: %d', rc)
  else
    log('audio subsystem initialized')
  end
end

local pet = pet_mod.new(ctx)
pet:create_window()
ctx.pet = pet

ctx.show_bubble = function(text, opts)
  pet:show_bubble(text, opts)
end

actions.quit = function()
  plugin_mgr.shutdown()
  ctx.emit('shutdown')
  if AUD then
    AUD.audio_shutdown()
  end
  pet:destroy()
  if xim then
    X11.XCloseIM(xim)
  end
  FT.xft_done(ft_ctx)
  X11.XCloseDisplay(d.dpy)
  os.exit(0)
end

actions.toggle_chase = function()
  pet:toggle_chase()
end
actions.toggle_freeze = function()
  pet:toggle_freeze()
end
actions.say_hello = function()
  pet:show_bubble('hello world 😀🎉')
  -- TODO: find a hello world audio to play, haha
  -- pet:play_audio()
  -- pet:play_behavior()
end

plugin_mgr.load_all(config.plugins or {}, ctx)

local keybinds = keybinds_mod.new({
  X11 = X11,
  bit = bit,
  dpy = d.dpy,
  root = d.root,
  log = log,
})
keybinds.rebuild(config)

local function do_hot_reload(silent)
  local ok, newcfg = pcall(load_config)
  if not ok then
    log('hot reload failed (config): %s', tostring(newcfg))
    if not silent then
      ctx.show_bubble('reload failed: config 😢')
    end
    return false
  end

  local font_changed = newcfg.font_path ~= config.font_path or newcfg.font_size ~= config.font_size
  if not font_changed then
    local a = table.concat(config.fallback_font_paths or {}, '\n')
    local b = table.concat(newcfg.fallback_font_paths or {}, '\n')
    font_changed = (a ~= b)
  end

  local pet_changed = newcfg.pet_source ~= config.pet_source
    or newcfg.pet_asset_dir ~= config.pet_asset_dir
    or (newcfg.scale_factor or 1) ~= (config.scale_factor or 1)
    or (newcfg.frame_duration or 200) ~= (config.frame_duration or 200)

  config = newcfg
  ctx.config = config

  -- 每个阶段独立 pcall：任一阶段失败只丢该阶段，绝不带崩主循环
  if font_changed then
    local okf, new_ft = pcall(load_font, config)
    if okf and new_ft then
      FT.xft_done(ft_ctx)
      ft_ctx = new_ft
      ctx.ft_ctx = new_ft
      log('font reloaded')
    else
      log('font reload failed, keeping old: %s', tostring(new_ft))
    end
  end

  local okp, perr = pcall(function()
    pet:apply_config(config) -- pet_speed / pet_frozen 等轻量字段
    if pet_changed then
      pet:reload_animations(config)
    end
  end)
  if not okp then
    log('hot reload failed (pet): %s', tostring(perr))
    if not silent then
      ctx.show_bubble('reload: pet failed 😢')
    end
  end

  local okr, rerr = pcall(plugin_mgr.reload, ctx, config.plugins or {})
  if not okr then
    log('hot reload failed (plugins): %s', tostring(rerr))
  end

  local okk, kerr = pcall(keybinds.rebuild, config)
  if not okk then
    log('hot reload failed (keybinds): %s', tostring(kerr))
  end

  if not silent then
    ctx.show_bubble('hot reload done 🚀')
  end
  return true
end

actions.hot_reload = function()
  do_hot_reload(false)
end

actions.toggle_auto_reload = function()
  local on = not plugin_mgr.watch_enabled
  plugin_mgr.set_watch(on)
  if on then
    plugin_mgr.snapshot_mtimes(ctx)
    ctx.show_bubble('auto-reload ON 👀')
  else
    ctx.show_bubble('auto-reload OFF 💤')
  end
end

local ev = ffi.new('XEvent')
local FRAME_MS = 16
local WATCH_INTERVAL_MS = 800
local watch_accum = 0

-- 实测帧间隔：换大帧时单次迭代远超 16ms，固定 dt 会拖慢动画
ffi.cdef[[
typedef struct { long tv_sec; long tv_nsec; } xp_timespec;
int clock_gettime(int clk, xp_timespec *tp);
]]
local ts = ffi.new('xp_timespec[1]')
local function now_ms()
  libc.clock_gettime(1, ts) -- CLOCK_MONOTONIC
  -- tonumber: cdata long 参与算术会传染成 cdata，下游 math.ceil 报 "number expected, got cdata"
  return tonumber(ts[0].tv_sec) * 1000 + tonumber(ts[0].tv_nsec) / 1e6
end

log('xpet running')

while true do
  local t0 = now_ms()

  while X11.XPending(d.dpy) > 0 do
    X11.XNextEvent(d.dpy, ev)

    local t = ev.type

    -- IME 优先过滤：如果当前有 IC 处于 focus 且正在合成，
    -- XFilterEvent 返回 True，我们就不处理这个事件
    if X11.XFilterEvent(ev, 0) == 0 then
      local consumed = ctx.emit('xevent', t, ev)

      if not consumed then
        if t == 2 then
          local action = keybinds.lookup(ev.xkey.keycode, ev.xkey.state)
          if action and actions[action] then
            local ok, err = pcall(actions[action])
            if not ok then
              log('action error: %s', tostring(err))
            end
          end
        else
          pet:handle_event(t, ev)
        end
      end
    end
  end

  libc.usleep(FRAME_MS * 1000)

  local dt = now_ms() - t0

  if plugin_mgr.watch_enabled then
    watch_accum = watch_accum + dt
    if watch_accum >= WATCH_INTERVAL_MS then
      watch_accum = 0
      if plugin_mgr.check_changes(ctx) then
        log('auto-reload triggered')
        do_hot_reload(true)
      end
    end
  end

  pet:tick(dt)
  ctx.emit('tick', dt)
end
