local M = {}
local ffi = require('ffi')
local Panel = require('core.panel')
local Util = require('core.util')
local X11C = require('core.x11_const')
local Keybinds = require('core.keybinds')

local log = Util.logger('music_player')

local function basename(p)
  return p:match('^.*/([^/]+)$') or p
end

local function strip_ext(s)
  return (s:gsub('%.[^%.]+$', ''))
end

local function fmt_time(s)
  if not s or s ~= s or s < 0 then
    return '--:--'
  end
  return string.format('%d:%02d', math.floor(s / 60), math.floor(s % 60))
end

local truncate = Util.truncate

local function scan(dir, AUD)
  if not dir or dir == '' then
    return {}
  end
  local n = AUD.audio_scan_dir(dir)
  if n <= 0 then
    return {}
  end
  local list = {}
  for i = 0, n - 1 do
    local p = AUD.audio_scan_get(i)
    if p ~= nil then
      local path = ffi.string(p)
      list[#list + 1] = {
        idx = #list + 1,
        path = path,
        title = strip_ext(basename(path)),
        duration = nil,
      }
    end
  end
  return list
end

local function fmt_keybind(ctx, action)
  for _, kb in ipairs(ctx.config.keybinds or {}) do
    if kb.action == action then
      local parts = {}
      for p in kb.mod:gmatch('[^+]+') do
        parts[#parts + 1] = p:sub(1, 1):upper() .. p:sub(2):lower()
      end
      parts[#parts + 1] = kb.key:upper()
      return table.concat(parts, '+')
    end
  end
  return '?'
end

local THEME = {
  bg = 0x141218,
  surface = 0x1d1b20,
  surface_hi = 0x2b2930,
  surface_hover = 0x3b383e,
  primary = 0xb69eff,
  primary_hi = 0xcfbcff,
  on_primary = 0x2e1065,
  secondary_ctr = 0x4a4458,
  on_surface = 0xe6e1e5,
  on_var = 0xcac4d0,
  outline = 0x938f99,
  green = 0xd6f26a,
  red = 0xf2b8b5,
}

local L_MUSIC = '音乐'
local L_PREV = '上首'
local L_NEXT = '下首'
local L_REW = '快退'
local L_FF = '快进'
local L_PLAY = '播放'
local L_PAUSE = '暂停'
local L_QUEUE = '播放队列'
local L_VOL = '音量'
local L_CLOSE = '×'

local S_READY = '就绪'
local S_PLAYING = '播放中'
local S_PAUSED = '已暂停'
local S_STOPPED = '已停止'
local S_NO_ART = '未知艺术家'
local S_NO_TRK = '未选择曲目'

local SEEK_STEP = 10

function M.init(ctx)
  M.ctx = ctx
  M.ready = false
  if not ctx.AUD then
    return
  end
  if ctx.AUD.audio_init() ~= 0 then
    return
  end
  M.ready = true

  local S = ctx._music_state or {}
  M.volume = S.volume or 80
  M.scroll = S.scroll or 0
  M.cur = S.cur or 0
  ctx.AUD.audio_set_volume(M.volume)

  M.toggle_hint = fmt_keybind(ctx, 'toggle_music_player')

  local lh = ctx.get_line_height()
  if ctx.get_primary_line_height then
    local plh = ctx.get_primary_line_height()
    if plh and plh >= 16 then
      lh = plh
    end
  end
  M.LH = lh
  M.PAD = 24
  M.W = math.min(ctx.scr_w - 80, 920)
  M.COVER = 96
  M.CTRL_H = lh + 28
  M.APPBAR = lh + 30
  M.SECT_H = lh + 16
  M.ROW_H = lh + 22
  M.BOTBAR = lh + 20
  M.INFO_H = 20 + M.COVER + 16 + 6 + (lh + 4) + 12 + M.CTRL_H + 20

  local top_h = M.APPBAR + M.INFO_H + M.SECT_H
  M.HMAX = math.min(ctx.scr_h - 120, 700)
  M.VROWS = math.max(3, math.floor((M.HMAX - top_h - M.BOTBAR) / M.ROW_H))
  M.H = top_h + M.VROWS * M.ROW_H + M.BOTBAR

  local function tw(s)
    return select(1, ctx.get_text_size(s))
  end
  local wmax = math.max(tw(L_PREV), tw(L_REW), tw(L_PLAY), tw(L_FF), tw(L_NEXT))
  M.BTN_W = wmax + 40
  M.BTN_GAP = 16

  M.playlist = scan(ctx.config.audio_panel_dir, ctx.AUD)
  M.filtered = M.playlist
  M.playing = false
  M.paused = false
  M.pos = 0
  M.dur = 0
  M.redraw = false
  M.poll = 0
  M.probe = 1
  M.search_query = ''

  M.panel = Panel.new(ctx, {
    w = M.W,
    h = M.H,
    y_shown = 0,
    theme = THEME,
    open_key = 'f',
    draw = function(p)
      M.draw(p)
    end,
    input = {
      placeholder = 'Ctrl+F 搜索',
      on_change = function(v)
        M.search_query = v
        M:apply_filter()
      end,
      on_submit = function()
        M.panel:blur_input()
      end,
      on_cancel = function()
        M.panel:blur_input()
      end,
    },
    on_show = function(p)
      if p._code_open and p._code_open ~= 0 then
        Keybinds.grab_root_key(ctx.X11, ctx.dpy, ctx.root, ctx.bit,
                               p._code_open, X11C.CONTROL_MASK)
      end
    end,
    on_hide = function(p)
      if p._code_open and p._code_open ~= 0 then
        Keybinds.ungrab_root_key(ctx.X11, ctx.dpy, ctx.root, ctx.bit,
                                 p._code_open, X11C.CONTROL_MASK)
      end
    end,
    on_wheel = function(p, btn, my)
      local l = M.LAYOUT(M)
      if my >= l.list_y and my < l.list_end then
        if btn == 4 then
          M.scroll = math.max(0, M.scroll - 1)
        else
          local mx_scroll = math.max(0, #M.filtered - M.VROWS)
          M.scroll = math.min(mx_scroll, M.scroll + 1)
        end
      end
    end,
    on_press = function(p, mx, my, btn, shift)
      local l = M.LAYOUT(M)
      local close_sz = 32
      local close_x = M.W - M.PAD - close_sz
      local close_y = math.floor((l.app_h - close_sz) / 2)
      if
        mx >= close_x
        and my >= close_y
        and mx < close_x + close_sz
        and my < close_y + close_sz
      then
        p:hide()
        return true
      end
      return my >= l.list_y and my < l.list_end
    end,
    tick = function(p, dt)
      local A = M.ctx.AUD
      if A.audio_finished() == 1 and #M.playlist > 0 then
        M.next()
      end
      M.poll = M.poll + dt
      if M.poll >= 200 then
        M.poll = 0
        local pl = A.audio_is_playing() ~= 0
        local pa = A.audio_is_paused() ~= 0
        local po = A.audio_get_position()
        local du = A.audio_get_duration()
        if pl ~= M.playing or pa ~= M.paused or po ~= M.pos or du ~= M.dur then
          M.playing, M.paused, M.pos, M.dur = pl, pa, po, du
          M.redraw = true
        end
      end
      if M.probe <= #M.playlist then
        local it = M.playlist[M.probe]
        if not it.duration then
          local d = A.audio_probe_duration(it.path)
          if d and d > 0 then
            it.duration = d
          end
          M.redraw = true
        end
        M.probe = M.probe + 1
      end
      if M.redraw or p.input.focused then
        p:draw()
        M.redraw = false
      end
    end,
  })

  ctx.register_action('toggle_music_player', function()
    M.toggle()
  end)
  ctx.on('tick', function(dt)
    M.tick(dt)
  end)
  ctx.on('xevent', function(t, ev)
    return M.on_ev(t, ev)
  end)

  log('ready: %d tracks, %dx%d lh=%d', #M.playlist, M.W, M.H, lh)
end

function M:apply_filter()
  local q = M.search_query
  if not q or q == '' then
    M.filtered = M.playlist
  else
    local ql = q:lower()
    local out = {}
    for _, it in ipairs(M.playlist) do
      if it.title:lower():find(ql, 1, true) then
        out[#out + 1] = it
      end
    end
    M.filtered = out
  end
  local mx = math.max(0, #M.filtered - M.VROWS)
  M.scroll = math.min(M.scroll, mx)
  M.scroll = math.max(0, M.scroll)
end

function M.toggle()
  if not M.ready then
    M.ctx.show_bubble('音频不可用 😢')
    return
  end
  M.panel:toggle()
end

function M.on_ev(t, ev)
  if not M.ready or not M.panel then
    return false
  end
  return M.panel:on_ev(t, ev)
end

function M.tick(dt)
  if not M.ready or not M.panel then
    return
  end
  M.panel:tick(dt)
end

function M.play_idx(i)
  if i < 1 or i > #M.playlist then
    return
  end
  M.cur = i
  M.ctx.AUD.audio_play(M.playlist[i].path)
  M.redraw = true
end

function M.toggle_pause()
  if M.cur == 0 then
    if #M.playlist > 0 then
      M.play_idx(1)
    end
    return
  end
  M.ctx.AUD.audio_toggle_pause()
  M.redraw = true
end

function M.next()
  if #M.playlist == 0 then
    return
  end
  M.play_idx(M.cur % #M.playlist + 1)
end

function M.prev()
  if #M.playlist == 0 then
    return
  end
  local p = M.cur - 1
  if p < 1 then
    p = #M.playlist
  end
  M.play_idx(p)
end

function M.seek_rel(delta)
  if M.dur <= 0 then
    return
  end
  local t = math.max(0, math.min(M.dur, M.pos + delta))
  M.pos = t
  M.ctx.AUD.audio_seek(t)
  M.redraw = true
end

function M.set_volume_pct(v)
  M.volume = math.max(0, math.min(100, math.floor(v)))
  M.ctx.AUD.audio_set_volume(M.volume)
  M.redraw = true
end

local function LAYOUT(M)
  local lh = M.LH
  local PAD = M.PAD
  local app_h = M.APPBAR
  local info_y = app_h
  local sect_y = info_y + M.INFO_H
  local list_y = sect_y + M.SECT_H
  local bot_y = M.H - M.BOTBAR

  local cover_x = PAD
  local cover_y = info_y + 20
  local info_x = cover_x + M.COVER + 20
  local info_w = M.W - info_x - PAD

  local prog_x = PAD
  local prog_y = cover_y + M.COVER + 16
  local prog_w = M.W - PAD * 2
  local prog_h = 6
  local time_y = prog_y + prog_h + 4
  local ctrl_y = time_y + lh + 8
  local ctrl_h = M.CTRL_H
  local total_w = M.BTN_W * 5 + M.BTN_GAP * 4
  local btn_x0 = math.floor((M.W - total_w) / 2)

  return {
    app_h = app_h,
    info_y = info_y,
    sect_y = sect_y,
    sect_h = M.SECT_H,
    list_y = list_y,
    list_end = bot_y,
    bot_y = bot_y,
    bot_h = M.BOTBAR,
    cover_x = cover_x,
    cover_y = cover_y,
    cover_sz = M.COVER,
    info_x = info_x,
    info_w = info_w,
    prog_x = prog_x,
    prog_y = prog_y,
    prog_w = prog_w,
    prog_h = prog_h,
    time_y = time_y,
    ctrl_y = ctrl_y,
    ctrl_h = ctrl_h,
    btn_x0 = btn_x0,
    btn_w = M.BTN_W,
    btn_gap = M.BTN_GAP,
  }
end
M.LAYOUT = LAYOUT

function M.draw(p)
  if not p.surf then
    return
  end
  local ui, s, T = p.ui, p.surf, p.ui.theme
  local lh = M.LH
  local l = LAYOUT(M)
  local tw = function(str)
    return select(1, M.ctx.get_text_size(str))
  end

  s:rect(0, 0, M.W, l.app_h, T.surface)
  local ay = math.floor((l.app_h - lh) / 2)
  local mus_w = tw(L_MUSIC)
  s:text(M.PAD, ay, L_MUSIC, T.primary)
  local cur = (M.cur > 0) and M.playlist[M.cur] or nil
  local sub = cur and cur.title or '—'
  s:text(M.PAD + mus_w + 16, ay, truncate(sub, 40), T.on_var)

  local close_sz = 32
  local close_x = M.W - M.PAD - close_sz
  local close_y = math.floor((l.app_h - close_sz) / 2)
  local hint_w = tw(M.toggle_hint)
  s:text(close_x - 16 - hint_w, ay, M.toggle_hint, T.outline)
  local close_hover = ui:hover(close_x, close_y, close_sz, close_sz)
  s:rrect(
    close_x,
    close_y,
    close_sz,
    close_sz,
    math.floor(close_sz / 2),
    close_hover and T.surface_hi or T.bg
  )
  local cl_w = tw(L_CLOSE)
  s:text(
    math.floor(close_x + close_sz / 2 - cl_w / 2),
    math.floor(close_y + (close_sz - lh) / 2),
    L_CLOSE,
    T.red
  )

  s:rect(0, l.app_h - 1, M.W, 1, T.outline)

  s:rrect(l.cover_x, l.cover_y, l.cover_sz, l.cover_sz, 20, T.surface_hi)
  local g_ts = '♪'
  local gw = tw(g_ts)
  s:text(
    math.floor(l.cover_x + l.cover_sz / 2 - gw / 2),
    math.floor(l.cover_y + l.cover_sz / 2 - lh / 2),
    g_ts,
    T.primary
  )

  local title = cur and cur.title or S_NO_TRK
  s:text(l.info_x, l.cover_y + 8, truncate(title, 48), T.on_surface)
  s:text(l.info_x, l.cover_y + 8 + lh + 6, cur and '' or S_NO_ART, T.on_var)

  if M.dur > 0 then
    local new_pos, changed = ui:slider(
      'mp_prog',
      l.prog_x,
      l.prog_y,
      l.prog_w,
      M.pos,
      { min = 0, max = M.dur, track = T.surface_hi, color = T.primary, handle = T.on_surface }
    )
    if changed then
      M.pos = new_pos
      M.ctx.AUD.audio_seek(M.pos)
    end
  else
    s:rrect(l.prog_x, l.prog_y, l.prog_w, 6, 3, T.surface_hi)
  end

  s:text(l.prog_x, l.time_y, fmt_time(M.pos), T.on_var)
  local dur_str = fmt_time(M.dur)
  local dur_w = tw(dur_str)
  s:text(l.prog_x + l.prog_w - dur_w, l.time_y, dur_str, T.on_var)

  local btns = {
    { 'prev', L_PREV, false },
    { 'rew', L_REW, false },
    { 'play', (M.playing and not M.paused) and L_PAUSE or L_PLAY, true },
    { 'ff', L_FF, false },
    { 'next', L_NEXT, false },
  }
  for i, item in ipairs(btns) do
    local bx = l.btn_x0 + (i - 1) * (l.btn_w + l.btn_gap)
    if
      ui:id_button('mp_' .. item[1], bx, l.ctrl_y, l.btn_w, l.ctrl_h, item[2], { filled = item[3] })
    then
      local k = item[1]
      if k == 'prev' then
        M.prev()
      elseif k == 'rew' then
        M.seek_rel(-SEEK_STEP)
      elseif k == 'play' then
        M.toggle_pause()
      elseif k == 'ff' then
        M.seek_rel(SEEK_STEP)
      elseif k == 'next' then
        M.next()
      end
    end
  end

  s:rect(0, l.sect_y, M.W, l.sect_h, T.bg)
  local sy = l.sect_y + math.floor((l.sect_h - lh) / 2)
  s:text(M.PAD, sy, L_QUEUE, T.primary)
  local cnt = string.format('%d / %d', M.cur, #M.playlist)
  local cnt_w = tw(cnt)
  s:text(M.W - M.PAD - cnt_w, sy, cnt, T.outline)

  local sq_w = 260
  local sq_h = lh + 4
  local sq_x = M.W - M.PAD - cnt_w - 16 - sq_w
  local sq_y = l.sect_y + math.floor((l.sect_h - sq_h) / 2)
  p.input:set_rect(sq_x, sq_y, sq_w, sq_h)
  p.input:draw(s, {
    bg = T.surface_hi,
    bg_focus = T.surface_hi,
    radius = math.floor(sq_h / 2),
    outline_focus = T.primary,
    text = T.on_surface,
    text_dim = T.on_var,
    cursor = T.primary,
    sel_bg = T.secondary_ctr,
  })
  s:rect(0, l.sect_y + l.sect_h - 1, M.W, 1, T.outline)

  local mx = math.max(0, #M.filtered - M.VROWS)
  for i = 1, M.VROWS do
    local li = M.scroll + i
    if li > #M.filtered then
      break
    end
    local it = M.filtered[li]
    local ry = l.list_y + (i - 1) * M.ROW_H
    local sel = (it.idx == M.cur)
    local row_bg = sel and T.surface_hi or T.bg
    s:rect(0, ry, M.W, M.ROW_H, row_bg)
    if sel then
      s:rect(0, ry, 4, M.ROW_H, T.primary)
    end
    local bsz = 28
    local bcy = ry + math.floor((M.ROW_H - bsz) / 2)
    local badge_bg = sel and T.primary or T.surface_hi
    local badge_fg = sel and T.on_primary or T.on_var
    s:rrect(M.PAD, bcy, bsz, bsz, 8, badge_bg)
    local num_str = string.format('%d', it.idx)
    local nw = tw(num_str)
    s:text(
      math.floor(M.PAD + bsz / 2 - nw / 2),
      math.floor(bcy + (bsz - lh) / 2),
      num_str,
      badge_fg
    )
    local tx = M.PAD + bsz + 16
    local ty = ry + math.floor((M.ROW_H - lh) / 2)
    s:text(tx, ty, truncate(it.title, 60), sel and T.on_surface or T.on_var)
    if it.duration then
      local ds = fmt_time(it.duration)
      local dw = tw(ds)
      s:text(M.W - M.PAD - dw, ty, ds, T.outline)
    end
    if i < M.VROWS and li < #M.filtered then
      s:rect(M.PAD, ry + M.ROW_H - 1, M.W - M.PAD * 2, 1, T.outline)
    end
    if ui:clicked(0, ry, M.W, M.ROW_H) then
      M.play_idx(it.idx)
    end
  end

  if mx > 0 then
    local track_h = M.VROWS * M.ROW_H
    local bh = math.max(32, math.floor(track_h * M.VROWS / #M.filtered))
    local by = l.list_y + math.floor((track_h - bh) * M.scroll / mx)
    s:rrect(M.W - 6, by, 4, bh, 2, T.outline)
  end

  s:rect(0, l.bot_y, M.W, l.bot_h, T.surface)
  s:rect(0, l.bot_y, M.W, 1, T.outline)
  local bty = l.bot_y + math.floor((l.bot_h - lh) / 2)
  local status
  if M.cur == 0 then
    status = S_READY
  elseif M.paused then
    status = S_PAUSED
  elseif M.playing then
    status = S_PLAYING
  else
    status = S_STOPPED
  end
  local dot_col = (M.playing and not M.paused) and T.green or T.outline
  s:rrect(M.PAD, bty + math.floor(lh / 2) - 4, 8, 8, 4, dot_col)
  s:text(M.PAD + 20, bty, status, T.on_var)

  if M.search_query ~= '' then
    local hint = string.format('筛选 %d / %d', #M.filtered, #M.playlist)
    local hw = tw(hint)
    s:text(math.floor(M.W / 2 - hw / 2), bty, hint, T.outline)
  end

  local pct_str = string.format('%d%%', M.volume)
  local pct_w = tw(pct_str)
  local vol_w = 100
  local vol_x = M.W - M.PAD - pct_w - 12 - vol_w
  local vol_lbl_w = tw(L_VOL)
  s:text(vol_x - 12 - vol_lbl_w, bty, L_VOL, T.on_var)
  local new_vol, changed = ui:slider(
    'mp_vol',
    vol_x,
    bty + math.floor(lh / 2) - 2,
    vol_w,
    M.volume,
    { min = 0, max = 100, track = T.surface_hi, color = T.green, handle = T.on_surface }
  )
  if changed then
    M.set_volume_pct(new_vol)
  end
  s:text(M.W - M.PAD - pct_w, bty, pct_str, T.on_var)
end

function M.shutdown()
  if M.ctx then
    M.ctx._music_state = {
      volume = M.volume,
      scroll = M.scroll,
      cur = M.cur,
    }
  end
  if M.panel then
    M.panel:destroy()
  end
  M.ready = false
end

return M