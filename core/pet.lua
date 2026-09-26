local M = {}
local ffi = require('ffi')
local Toast = require('core.toast')
local X11C = require('core.x11_const')
local PetSource = require('core.pet_source')
local Behavior = require('core.behavior')

function M.new(ctx)
  local X11 = ctx.X11
  local Xext = ctx.Xext
  local dpy = ctx.dpy
  local root = ctx.root
  local depth = ctx.depth
  local scr_w = ctx.scr_w
  local scr_h = ctx.scr_h
  local config = ctx.config
  local log = ctx.log

  local pet = {
    win = nil,
    gc = nil,
    state = 'idle',
    frame = 1,
    frame_time = 0,
    x = math.floor(scr_w / 2),
    y = math.floor(scr_h / 2),
    w = 64,
    h = 64,
    animations = {},
  }

  -- Toast 实例（用于替代旧的白色气泡窗口）
  pet.toast = Toast.new(ctx)

  local function free_animations()
    local seen = {}
    for _, frames in pairs(pet.animations) do
      if not seen[frames] then
        seen[frames] = true
        for _, fr in ipairs(frames) do
          X11.XFreePixmap(dpy, fr.pix)
          X11.XFreePixmap(dpy, fr.mask)
        end
      end
    end
    pet.animations = {}
  end

  -- 素材由 PetSource 后端加载（XPM / 未来 PNG、GIF）
  function pet:load_animations()
    pet.animations = PetSource.load(ctx, config)
    log('animations: idle=%d frames', #(pet.animations.idle or {}))
  end

  function pet:current_frames()
    return pet.animations[pet.state] or pet.animations.idle or {}
  end

  function pet:current_frame()
    local fs = pet:current_frames()
    return fs[pet.frame] or fs[1]
  end

  function pet:create_window()
    local f = pet:current_frame()
    if not f then
      error('no frames available')
    end
    pet.w, pet.h = f.w, f.h
    local attrs = ffi.new('XSetWindowAttributes')
    attrs.override_redirect = 1
    attrs.background_pixmap = f.pix
    attrs.border_pixel = 0
    local mask = X11C.CW_OVERRIDE_REDIRECT + X11C.CW_BACK_PIXMAP + X11C.CW_BORDER_PIXEL
    pet.win = X11.XCreateWindow(
      dpy,
      root,
      pet.x,
      pet.y,
      pet.w,
      pet.h,
      0,
      depth,
      1,
      nil,
      mask,
      attrs
    )
    X11.XSelectInput(dpy, pet.win, X11C.INPUT_MASK_BASE)
    Xext.XShapeCombineMask(dpy, pet.win, 0, 0, 0, f.mask, 0)
    X11.XSetWindowBackgroundPixmap(dpy, pet.win, f.pix)
    X11.XMapWindow(dpy, pet.win)
    X11.XRaiseWindow(dpy, pet.win)
    X11.XFlush(dpy)
    pet.gc = X11.XCreateGC(dpy, pet.win, 0, nil)
  end

  function pet:apply_frame()
    local f = pet:current_frame()
    if not f then
      return
    end
    Xext.XShapeCombineMask(dpy, pet.win, 0, 0, 0, f.mask, 0)
    X11.XSetWindowBackgroundPixmap(dpy, pet.win, f.pix)
    X11.XClearWindow(dpy, pet.win)
  end

  function pet:set_state(name)
    if pet.state ~= name and pet.animations[name] and #pet.animations[name] > 0 then
      pet.state = name
      pet.frame = 1
      pet.frame_time = 0
      pet:apply_frame()
    end
  end

  function pet:move_to(x, y)
    pet.x, pet.y = x, y
    X11.XMoveWindow(dpy, pet.win, math.floor(x), math.floor(y))
  end

  function pet:query_mouse()
    local rr = ffi.new('Window[1]')
    local cr = ffi.new('Window[1]')
    local rx = ffi.new('int[1]')
    local ry = ffi.new('int[1]')
    local wx = ffi.new('int[1]')
    local wy = ffi.new('int[1]')
    local mask = ffi.new('unsigned int[1]')
    X11.XQueryPointer(dpy, root, rr, cr, rx, ry, wx, wy, mask)
    return rx[0], ry[0]
  end

  -- 行为（漫游/追踪/冻结/拖拽）由表驱动状态机接管
  pet.behavior = Behavior.new(pet, {
    speed = config.pet_speed or 2,
    margin = 100,
    screen_w = scr_w,
    screen_h = scr_h,
    idle_anim = 'idle',
    wait_min = 16000,
    wait_max = 32000,
    query_mouse = function()
      return pet:query_mouse()
    end,
  })

  function pet:tick(dt_ms)
    local fs = pet:current_frames()
    if #fs > 0 then
      pet.frame_time = pet.frame_time + dt_ms
      if pet.frame_time >= (config.frame_duration or 200) then
        pet.frame_time = 0
        pet.frame = pet.frame % #fs + 1
        pet:apply_frame()
      end
    end

    -- 气泡由 toast 统一驱动
    pet.toast:tick(dt_ms)

    pet.behavior:tick(dt_ms)
  end

  function pet:reload_animations(new_config)
    config = new_config

    free_animations()

    if pet.win then
      X11.XDestroyWindow(dpy, pet.win)
      pet.win = nil
    end
    if pet.gc then
      X11.XFreeGC(dpy, pet.gc)
      pet.gc = nil
    end

    pet:load_animations()

    pet.state = 'idle'
    pet.frame = 1
    pet.frame_time = 0
    pet.behavior.o.speed = config.pet_speed or 2
    pet:create_window()
    pet.behavior:reset()
  end

  function pet:set_config(new_config)
    config = new_config
  end

  function pet:toggle_chase()
    local b = pet.behavior
    if b.mode == 'chase' then
      b:set_mode('wander')
    else
      b:set_mode('chase')
    end
  end

  function pet:toggle_freeze()
    local b = pet.behavior
    if b.mode == 'frozen' then
      b:set_mode(b.prev_mode or 'wander')
    else
      b.prev_mode = b.mode
      b:set_mode('frozen')
    end
  end

  -- ─── 气泡：委托给 toast 组件 ──────────────────────────────
  function pet:show_bubble(text, opts)
    if not text or text == '' then
      return
    end
    opts = opts or {}
    pet.toast:show(text, {
      duration = opts.duration or 3.0,
      style = opts.style or 'plain',
      anchor = function(t)
        local tx = pet.x + pet.w * 0.5 - t.w * 0.5
        if tx < 10 then
          tx = 10
        end
        if tx > scr_w - 10 - t.w then
          tx = scr_w - 10 - t.w
        end
        local ty = pet.y - t.h - 10
        if ty < 10 then
          ty = pet.y + pet.h + 10
        end
        return tx, ty
      end,
    })
  end

  function pet:play_audio()
    if not ctx.AUD then
      return
    end
    local cfg = ctx.config
    if not cfg or not cfg.enable_audio then
      return
    end
    local path = cfg.click_audio_to_play
    if not path or path == '' then
      return
    end
    local f = io.open(path, 'rb')
    if not f then
      return
    end
    f:close()
    local rc = ctx.AUD.audio_play_sfx(path, 80)
    if rc < 0 then
      log('audio_play_sfx failed (rc=%d), falling back to ffplay', rc)
      os.execute(
        string.format("ffplay -nodisp -autoexit -loglevel error '%s' >/dev/null 2>&1 &", path)
      )
    end
  end

  function pet:handle_event(t, ev)
    if t == 4 then
      if ev.xbutton.window == pet.win then
        pet:play_audio()
        if ev.xbutton.button == 1 then
          pet.behavior.dragging = true
          pet.drag_off_x = ev.xbutton.x
          pet.drag_off_y = ev.xbutton.y
          pet:set_state('dragged')
        elseif ev.xbutton.button == 3 then
          local ph = config.phrases
          if ph and #ph > 0 then
            pet:show_bubble(ph[math.random(1, #ph)])
          end
        end
      end
    elseif t == 5 then
      if ev.xbutton.window == pet.win and ev.xbutton.button == 1 then
        pet.behavior.dragging = false
        pet:set_state('idle')
        pet.behavior:reset()
      end
    elseif t == 6 then
      if pet.behavior.dragging and ev.xmotion.window == pet.win then
        pet.x = ev.xmotion.x_root - pet.drag_off_x
        pet.y = ev.xmotion.y_root - pet.drag_off_y
        X11.XMoveWindow(dpy, pet.win, pet.x, pet.y)
        -- 气泡位置由 toast 的 anchor 自动跟随，无需手动搬
      end
    elseif t == 12 then
      if ev.xexpose.window == pet.win then
        pet:apply_frame()
      end
    end
  end

  function pet:destroy()
    pet.toast:clear()

    if pet.win then
      X11.XDestroyWindow(dpy, pet.win)
    end
    if pet.gc then
      X11.XFreeGC(dpy, pet.gc)
    end
    free_animations()
  end

  pet:load_animations()
  pet.behavior:reset()
  return pet
end

return M
