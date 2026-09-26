local M = {}
local ffi = require("ffi")

local function log(fmt, ...) io.stderr:write("[music_player] " .. string.format(fmt, ...) .. "\n") end
local function basename(p) return p:match("^.*/([^/]+)$") or p end
local function strip_ext(s) return (s:gsub("%.[^%.]+$", "")) end

local function fmt_time(s)
    if not s or s ~= s or s < 0 then return "--:--" end
    return string.format("%d:%02d", math.floor(s/60), math.floor(s%60))
end

local function truncate(s, max)
    if #s <= max then return s end
    local cut = max - 1
    while cut > 0 do
        local b = s:byte(cut + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end
        cut = cut - 1
    end
    return s:sub(1, cut) .. "…"
end

local function scan(dir, AUD)
    if not dir or dir == "" then return {} end
    local n = AUD.audio_scan_dir(dir)
    if n <= 0 then return {} end
    local list = {}
    for i = 0, n - 1 do
        local p = AUD.audio_scan_get(i)
        if p ~= nil then
            local path = ffi.string(p)
            list[#list + 1] = { path = path, title = strip_ext(basename(path)), duration = nil }
        end
    end
    return list
end

local function fmt_keybind(ctx, action)
    for _, kb in ipairs(ctx.config.keybinds or {}) do
        if kb.action == action then
            local parts = {}
            for p in kb.mod:gmatch("[^+]+") do
                parts[#parts + 1] = p:sub(1,1):upper() .. p:sub(2):lower()
            end
            parts[#parts + 1] = kb.key:upper()
            return table.concat(parts, "+")
        end
    end
    return "?"
end

-- ─── Material Design 3 – Dark tonal palette ────────────────
local M_BG        = 0x141218   -- surface-dim
local M_SURF      = 0x1d1b20   -- surface
local M_SURF_LOW  = 0x211f26   -- surface-container-low
local M_SURF_HIGH = 0x2b2930   -- surface-container-high
local M_SURF_HI2  = 0x36343b   -- surface-container-highest
local M_PRIMARY   = 0xd0bcff
local M_ON_PRIM   = 0x381e72
local M_PRIM_CONT = 0x4f378b
local M_ON_SURF   = 0xe6e1e5
local M_ON_VAR    = 0xcac4d0
local M_OUTLINE   = 0x938f99
local M_OUTL_VAR  = 0x49454f
local M_ERR       = 0xf2b8b5
local M_GREEN     = 0xb5ccb5

-- ─── Chinese labels ────────────────────────────────────────
local L_MUSIC = "音乐"
local L_PREV  = "上首"
local L_NEXT  = "下首"
local L_REW   = "快退"
local L_FF    = "快进"
local L_PLAY  = "播放"
local L_PAUSE = "暂停"
local L_QUEUE = "播放队列"
local L_VOL   = "音量"
local L_CLOSE = "关闭"

local S_READY   = "就绪"
local S_PLAYING = "播放中"
local S_PAUSED  = "已暂停"
local S_STOPPED = "已停止"
local S_NO_ART  = "未知艺术家"
local S_NO_TRK  = "未选择曲目"

local SEEK_STEP = 10

-- ─── Dimensions (Material 3 – 8dp grid) ────────────────────
local function build_metrics(ctx)
    local lh = ctx.get_line_height()
    return {
        LH      = lh,
        PAD     = 24,           -- 16dp horizontal pad, scaled
        W       = math.min(ctx.scr_w - 80, 1000),
        APPBAR  = lh + 32,      -- top app bar
        INFO_H  = lh * 5,       -- track info card
        SECT_H  = lh + 12,      -- section header
        ROW_H   = lh + 24,      -- row height (touch target)
        BOTBAR  = lh + 20,
    }
end

function M.init(ctx)
    M.ctx = ctx
    M.visible = false
    M.ready = false
    if not ctx.AUD then return end
    if ctx.AUD.audio_init() ~= 0 then return end
    M.ready = true

    local S = ctx._music_state or {}
    M.volume = S.volume or 80
    M.scroll = S.scroll or 0
    M.cur    = S.cur or 0
    ctx.AUD.audio_set_volume(M.volume)
    M.toggle_hint = fmt_keybind(ctx, "toggle_music_player")

    local mt = build_metrics(ctx)
    for k, v in pairs(mt) do M[k] = v end

    -- precompute button widths from label sizes
    local function text_w(s) return select(1, ctx.get_text_size(s)) end
    M.BTN_W = {}
    for _, key in ipairs({"prev","rew","play","ff","next"}) do
        local label
        if key == "prev" then label = L_PREV
        elseif key == "rew" then label = L_REW
        elseif key == "play" then label = L_PLAY
        elseif key == "ff" then label = L_FF
        else label = L_NEXT end
        M.BTN_W[key] = text_w(label) + M.PAD
    end

    -- layout aggregate
    local top_h = M.APPBAR + M.INFO_H + M.SECT_H
    M.HMAX  = math.min(ctx.scr_h - 120, 640)
    M.VROWS = math.max(3, math.floor((M.HMAX - top_h - M.BOTBAR) / M.ROW_H))
    M.H     = top_h + M.VROWS * M.ROW_H + M.BOTBAR
    M.X     = math.floor((ctx.scr_w - M.W) / 2)
    M.YH    = -(M.H + 4)
    M.YS    = 0

    M.playlist = scan(ctx.config.audio_panel_dir, ctx.AUD)
    M.playing  = false
    M.paused   = false
    M.pos      = 0
    M.dur      = 0
    M.drag     = nil
    M.redraw   = false
    M.poll     = 0
    M.probe    = 1
    M.anim_y   = M.YH
    M.target_y = M.YH

    ctx.register_action("toggle_music_player", function() M.toggle() end)
    ctx.on("tick",   function(dt) M.tick(dt) end)
    ctx.on("xevent", function(t, ev) M.on_ev(t, ev) end)

    log("M3 ready: %d tracks, %dx%d", #M.playlist, M.W, M.H)
end

function M.cv()
    if M.canvas then return end
    M.canvas = M.ctx.create_canvas(M.W, M.H, {
        x = M.X, y = M.YH, bg = M_BG, border = M_BG, border_width = 1,
    })
end

function M.show()
    M.cv()
    M.anim_y, M.target_y = M.YH, M.YS
    M.canvas.move(M.X, M.anim_y)
    M.draw()
    M.canvas.show()
    M.visible = true
end

function M.hide()
    M.target_y = M.YH
    M.visible  = false
end

function M.toggle()
    if not M.ready then M.ctx.show_bubble("音频不可用 😢"); return end
    if M.visible then M.hide() else M.show() end
end

function M.play_idx(i)
    if i < 1 or i > #M.playlist then return end
    M.cur = i
    M.ctx.AUD.audio_play(M.playlist[i].path)
    M.redraw = true
end

function M.toggle_pause()
    if M.cur == 0 then
        if #M.playlist > 0 then M.play_idx(1) end
        return
    end
    M.ctx.AUD.audio_toggle_pause()
    M.redraw = true
end

function M.next()
    if #M.playlist == 0 then return end
    M.play_idx(M.cur % #M.playlist + 1)
end

function M.prev()
    if #M.playlist == 0 then return end
    local p = M.cur - 1
    if p < 1 then p = #M.playlist end
    M.play_idx(p)
end

function M.seek(r)
    r = math.max(0, math.min(1, r))
    if M.dur > 0 then
        M.pos = r * M.dur
        M.ctx.AUD.audio_seek(M.pos)
        M.redraw = true
    end
end

function M.seek_rel(delta)
    if M.dur <= 0 then return end
    local t = math.max(0, math.min(M.dur, M.pos + delta))
    M.pos = t
    M.ctx.AUD.audio_seek(t)
    M.redraw = true
end

function M.set_vol(r)
    M.volume = math.floor(math.max(0, math.min(1, r)) * 100)
    M.ctx.AUD.audio_set_volume(M.volume)
    M.redraw = true
end

-- ─── Layout regions ────────────────────────────────────────
local function LAYOUT(M)
    local y0 = M.APPBAR
    local y1 = y0 + M.INFO_H
    local y2 = y1 + M.SECT_H
    local list_end = M.H - M.BOTBAR
    local cx = M.W / 2
    local BW = M.BTN_W
    local gap = 20
    local play_w = BW.play
    local prev_right = cx - play_w/2 - gap
    local prev_left  = prev_right - BW.prev
    local rew_right  = prev_left  - gap
    local rew_left   = rew_right  - BW.rew
    local next_left  = cx + play_w/2 + gap
    local next_right = next_left + BW.next
    local ff_left    = next_right + gap
    local ff_right   = ff_left + BW.ff
    return {
        app_y     = 0,
        app_h     = M.APPBAR,
        info_y    = y0,
        info_h    = M.INFO_H,
        sect_y    = y1,
        sect_h    = M.SECT_H,
        list_y    = y2,
        list_end  = list_end,
        bot_y     = list_end,
        bot_h     = M.BOTBAR,
        -- progress bar
        prog_x    = M.PAD,
        prog_w    = M.W - M.PAD * 2,
        prog_y    = y0 + M.INFO_H - 40,
        prog_h    = 6,
        -- controls row
        ctrl_y    = y0 + M.INFO_H - 92,
        ctrl_h    = 48,
        -- button rects
        prev = { x = prev_left,  w = BW.prev  },
        rew  = { x = rew_left,   w = BW.rew   },
        play = { x = cx - play_w/2, w = play_w },
        ff   = { x = ff_left,    w = BW.ff    },
        next = { x = next_left,  w = BW.next  },
        -- volume
        vol_x     = M.W - M.PAD - 140,
        vol_w     = 100,
    }
end
M.LAYOUT = LAYOUT

-- ─── Hit testing ───────────────────────────────────────────
function M.hit(x, y)
    local l = LAYOUT(M)
    -- close button: right 48px of app bar
    if y < l.app_h and x >= M.W - M.PAD - 40 then return "close" end

    -- control buttons
    if y >= l.ctrl_y and y < l.ctrl_y + l.ctrl_h then
        for _, k in ipairs({"prev","rew","play","ff","next"}) do
            local b = l[k]
            if x >= b.x and x < b.x + b.w then return k end
        end
    end

    -- progress bar
    if y >= l.prog_y - 8 and y < l.prog_y + l.prog_h + 8 then
        if x >= l.prog_x and x <= l.prog_x + l.prog_w then return "seek" end
    end

    -- playlist
    if y >= l.list_y and y < l.list_end then
        local row = math.floor((y - l.list_y) / M.ROW_H) + 1
        if row >= 1 and row <= M.VROWS then
            local i = M.scroll + row
            if i >= 1 and i <= #M.playlist then return "track:" .. i end
        end
    end

    -- volume
    if y >= l.bot_y and y < M.H then
        if x >= l.vol_x and x <= l.vol_x + l.vol_w then return "volume" end
    end
end

function M.on_ev(t, ev)
    if not M.ready or not M.canvas or not M.visible then return end
    if t == 4 then
        if ev.xbutton.window ~= M.canvas.win then return end
        if ev.xbutton.button == 4 then
            M.scroll = math.max(0, M.scroll - 1); M.redraw = true; return
        end
        if ev.xbutton.button == 5 then
            local mx = math.max(0, #M.playlist - M.VROWS)
            M.scroll = math.min(mx, M.scroll + 1); M.redraw = true; return
        end
        local x, y = ev.xbutton.x, ev.xbutton.y
        local h = M.hit(x, y)
        M.drag = nil
        local l = LAYOUT(M)
        if h == "close" then M.hide()
        elseif h == "play" then M.toggle_pause()
        elseif h == "prev" then M.prev()
        elseif h == "next" then M.next()
        elseif h == "rew"  then M.seek_rel(-SEEK_STEP)
        elseif h == "ff"   then M.seek_rel( SEEK_STEP)
        elseif h == "seek" then M.drag = "seek"; M.seek((x - l.prog_x) / l.prog_w)
        elseif h == "volume" then M.drag = "volume"; M.set_vol((x - l.vol_x) / l.vol_w)
        elseif h and h:sub(1, 6) == "track:" then M.play_idx(tonumber(h:sub(7))) end
    elseif t == 5 then
        if ev.xbutton.window == M.canvas.win then M.drag = nil end
    elseif t == 6 then
        if ev.xmotion.window ~= M.canvas.win then return end
        local l = LAYOUT(M)
        if M.drag == "seek" then M.seek((ev.xmotion.x - l.prog_x) / l.prog_w)
        elseif M.drag == "volume" then M.set_vol((ev.xmotion.x - l.vol_x) / l.vol_w) end
    elseif t == 12 then
        if ev.xexpose.window == M.canvas.win then M.redraw = true end
    end
end

function M.tick(dt)
    if not M.ready or not M.canvas then return end
    if M.anim_y ~= M.target_y then
        local d = M.target_y - M.anim_y
        if math.abs(d) < 1.5 then M.anim_y = M.target_y else M.anim_y = M.anim_y + d * 0.3 end
        M.canvas.move(M.X, math.floor(M.anim_y))
        if M.anim_y == M.target_y and M.target_y < 0 then M.canvas.hide(); return end
    end
    if not M.visible then return end
    local A = M.ctx.AUD
    if A.audio_finished() == 1 and #M.playlist > 0 then M.next() end
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
            local d = M.ctx.AUD.audio_probe_duration(it.path)
            if d and d > 0 then it.duration = d end
            M.redraw = true
        end
        M.probe = M.probe + 1
    end
    if M.redraw then M.draw(); M.redraw = false end
end

-- ─── Drawing ───────────────────────────────────────────────
local function tsize(ctx, s) return ctx.get_text_size(s) end

local function draw_centered(ctx, c, text, cx, cy, lh, fg, bg)
    local w = select(1, ctx.get_text_size(text))
    c:text(math.floor(cx - w/2), math.floor(cy - lh/2), text, fg, bg)
end

function M.draw()
    if not M.canvas then return end
    local c, ctx, lh = M.canvas, M.ctx, M.LH
    local l = LAYOUT(M)
    c:clear()

    -- ═══════════ Top app bar ═══════════
    c:rect(0, 0, M.W, l.app_h, M_SURF_LOW)

    -- left: leading icon + title (row 1)
    local pad_l = M.PAD
    local app_cy = l.app_h / 2
    -- title
    local tsize_w = select(1, tsize(ctx, L_MUSIC))
    c:text(pad_l, math.floor(app_cy - lh/2), L_MUSIC, M_PRIMARY, M_SURF_LOW)
    -- current track name to the right of title
    local cur = (M.cur > 0) and M.playlist[M.cur] or nil
    local sub = cur and cur.title or "—"
    c:text(pad_l + tsize_w + 20, math.floor(app_cy - lh/2), truncate(sub, 40), M_ON_VAR, M_SURF_LOW)

    -- right: keybind + close
    local hint_w = select(1, tsize(ctx, M.toggle_hint))
    c:text(M.W - M.PAD - 40 - 16 - hint_w,
           math.floor(app_cy - lh/2), M.toggle_hint, M_OUTLINE, M_SURF_LOW)
    -- close button (rounded square)
    local cbx = M.W - M.PAD - 32
    local cby = math.floor(app_cy - 16)
    c:rrect(cbx, cby, 32, 32, 16, M_SURF_HIGH)
    local cl_w = select(1, tsize(ctx, "✕"))
    c:text(math.floor(cbx + 16 - cl_w/2), math.floor(cby + 16 - lh/2), "✕", M_ERR, M_SURF_HIGH)

    c:rect(0, l.app_h - 1, M.W, 1, M_OUTL_VAR)

    -- ═══════════ Info card ═══════════
    c:rect(0, l.info_y, M.W, l.info_h, M_BG)

    -- cover art card (rounded)
    local cov = 128
    local cx0 = M.PAD
    local cy0 = l.info_y + 20
    c:rrect(cx0, cy0, cov, cov, 20, M_SURF_HIGH)
    -- music glyph inside cover
    local g_ts = "♪"
    local gw = select(1, tsize(ctx, g_ts))
    c:text(math.floor(cx0 + cov/2 - gw/2),
           math.floor(cy0 + cov/2 - lh/2), g_ts, M_PRIMARY, M_SURF_HIGH)

    -- track title + artist
    local ix = cx0 + cov + 20
    local title = cur and cur.title or S_NO_TRK
    c:text(ix, l.info_y + 24, truncate(title, 48), M_ON_SURF, M_BG)
    c:text(ix, l.info_y + 24 + lh + 6,
           cur and S_NO_ART or "", M_ON_VAR, M_BG)

    -- elapsed / total on right
    local ts_str = fmt_time(M.pos) .. "  /  " .. fmt_time(M.dur)
    local tsw = select(1, tsize(ctx, ts_str))
    c:text(M.W - M.PAD - tsw, l.info_y + 24 + lh + 6, ts_str, M_ON_VAR, M_BG)

    -- ─── progress bar (rounded) ───
    local py = l.prog_y
    c:rrect(l.prog_x, py, l.prog_w, l.prog_h, 3, M_SURF_HIGH)
    if M.dur > 0 then
        local fill = math.max(8, math.floor(l.prog_w * M.pos / M.dur))
        c:rrect(l.prog_x, py, fill, l.prog_h, 3, M_PRIMARY)
        -- handle
        local hx = l.prog_x + fill - 8
        c:rrect(hx, py - 6, 16, l.prog_h + 12, 8, M_ON_SURF)
    end

    -- ─── Transport controls ───
    local by = l.ctrl_y
    local bh = l.ctrl_h

    local function btn(bx, bw, label, filled)
        if filled then
            c:rrect(bx, by, bw, bh, 24, M_PRIMARY)
            draw_centered(ctx, c, label, bx + bw/2, by + bh/2, lh, M_ON_PRIM, M_PRIMARY)
        else
            c:rrect(bx, by, bw, bh, 24, M_SURF_HIGH)
            draw_centered(ctx, c, label, bx + bw/2, by + bh/2, lh, M_ON_SURF, M_SURF_HIGH)
        end
    end
    
    btn(l.prev.x, l.prev.w, L_PREV, false)
    btn(l.rew.x,  l.rew.w,  L_REW,  false)
    btn(l.play.x, l.play.w, (M.playing and not M.paused) and L_PAUSE or L_PLAY, true)
    btn(l.ff.x,   l.ff.w,   L_FF,   false)
    btn(l.next.x, l.next.w, L_NEXT, false)

    -- ═══════════ Section header ═══════════
    c:rect(0, l.sect_y, M.W, l.sect_h, M_BG)
    local scy = l.sect_y + math.floor((l.sect_h - lh)/2)
    c:text(M.PAD, scy, L_QUEUE, M_PRIMARY, M_BG)
    local qcnt = string.format("%d / %d", M.cur, #M.playlist)
    local qcw = select(1, tsize(ctx, qcnt))
    c:text(M.W - M.PAD - qcw, scy, qcnt, M_OUTLINE, M_BG)
    c:rect(0, l.sect_y + l.sect_h - 1, M.W, 1, M_OUTL_VAR)

    -- ═══════════ Playlist ═══════════
    local ly = l.list_y
    local mx = math.max(0, #M.playlist - M.VROWS)
    if M.scroll > mx then M.scroll = mx end
    for i = 1, M.VROWS do
        local idx = M.scroll + i
        if idx > #M.playlist then break end
        local ry = ly + (i - 1) * M.ROW_H
        local it = M.playlist[idx]
        local sel = (idx == M.cur)
        local bg  = sel and M_SURF_HIGH or M_BG
        c:rect(0, ry, M.W, M.ROW_H, bg)

        -- active indicator bar
        if sel then c:rect(0, ry, 4, M.ROW_H, M_PRIMARY) end

        -- track number badge (rounded)
        local bx = M.PAD
        local bsz = 32
        local bcy = ry + math.floor((M.ROW_H - bsz)/2)
        local badge_bg = sel and M_PRIMARY or M_SURF_HIGH
        local badge_fg = sel and M_ON_PRIM or M_ON_VAR
        c:rrect(bx, bcy, bsz, bsz, 8, badge_bg)
        local num = string.format("%d", idx)
        local nw = select(1, tsize(ctx, num))
        c:text(math.floor(bx + bsz/2 - nw/2), math.floor(bcy + bsz/2 - lh/2), num, badge_fg, badge_bg)

        -- playing indicator (small dot)
        local tx = M.PAD + bsz + 16
        if sel and M.playing and not M.paused then
            c:rrect(tx, ry + math.floor(M.ROW_H/2) - 3, 6, 6, 3, M_GREEN)
            tx = tx + 16
        end

        -- title
        local ty = ry + math.floor((M.ROW_H - lh)/2)
        c:text(tx, ty, truncate(it.title, 56),
               sel and M_ON_SURF or M_ON_VAR, bg)

        -- duration
        if it.duration then
            local ds = fmt_time(it.duration)
            local dw = select(1, tsize(ctx, ds))
            c:text(M.W - M.PAD - dw, ty, ds, M_OUTLINE, bg)
        end

        -- divider
        if i < M.VROWS and idx < #M.playlist then
            c:rect(M.PAD, ry + M.ROW_H - 1, M.W - M.PAD * 2, 1, M_OUTL_VAR)
        end
    end

    -- scrollbar
    if mx > 0 then
        local track_h = M.VROWS * M.ROW_H
        local bh = math.max(32, math.floor(track_h * M.VROWS / #M.playlist))
        local by = ly + math.floor((track_h - bh) * M.scroll / mx)
        c:rrect(M.W - 6, by, 4, bh, 2, M_OUTLINE)
    end

    -- ═══════════ Bottom bar ═══════════
    c:rect(0, l.bot_y - 1, M.W, 1, M_OUTL_VAR)
    c:rect(0, l.bot_y, M.W, l.bot_h, M_SURF_LOW)
    local bty = l.bot_y + math.floor((l.bot_h - lh)/2)

    local status
    if M.cur == 0 then status = S_READY
    elseif M.paused then status = S_PAUSED
    elseif M.playing then status = S_PLAYING
    else status = S_STOPPED end
    local dot_col = M.playing and not M.paused and M_GREEN or M_OUTLINE
    c:rrect(M.PAD, bty + math.floor(lh/2) - 4, 8, 8, 4, dot_col)
    c:text(M.PAD + 20, bty, status, M_ON_VAR, M_SURF_LOW)

    -- volume
    local vol_x = l.vol_x
    local vw = l.vol_w
    local vol_lbl_w = select(1, tsize(ctx, L_VOL))
    c:text(vol_x - vol_lbl_w - 12, bty, L_VOL, M_ON_VAR, M_SURF_LOW)
    local vy = bty + math.floor(lh/2) - 2
    c:rrect(vol_x, vy, vw, 4, 2, M_SURF_HI2)
    local fw = math.max(8, math.floor(vw * M.volume / 100))
    c:rrect(vol_x, vy, fw, 4, 2, M_GREEN)
    -- handle
    c:rrect(vol_x + fw - 7, vy - 5, 14, 14, 7, M_ON_SURF)
    local vtxt = string.format("%d%%", M.volume)
    c:text(vol_x + vw + 12, bty, vtxt, M_ON_VAR, M_SURF_LOW)

    c:flush()
end

function M.shutdown()
    if M.ctx then
        M.ctx._music_state = {
            volume = M.volume,
            scroll = M.scroll,
            cur    = M.cur,
        }
    end
    if M.canvas then M.canvas.destroy() end
    M.ready = false
end

return M