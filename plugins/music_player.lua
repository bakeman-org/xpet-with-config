local M = {}
local ffi = require("ffi")
local UI = require("core.ui")
local Surface = require("core.surface")

-- ─── 辅助函数 ─────────────────────────────────────────
local function log(fmt, ...)
    io.stderr:write("[music_player] " .. string.format(fmt, ...) .. "\n")
end

local function basename(p) return p:match("^.*/([^/]+)$") or p end
local function strip_ext(s) return (s:gsub("%.[^%.]+$", "")) end

local function fmt_time(s)
    if not s or s ~= s or s < 0 then return "--:--" end
    return string.format("%d:%02d", math.floor(s / 60), math.floor(s % 60))
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
            list[#list + 1] = {
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
            for p in kb.mod:gmatch("[^+]+") do
                parts[#parts + 1] = p:sub(1, 1):upper() .. p:sub(2):lower()
            end
            parts[#parts + 1] = kb.key:upper()
            return table.concat(parts, "+")
        end
    end
    return "?"
end

-- ─── Material 3 深色主题（覆盖 UI 默认值）─────────────
local THEME = {
    bg            = 0x141218,
    surface       = 0x1d1b20,
    surface_hi    = 0x2b2930,
    surface_hover = 0x3b383e,
    primary       = 0xb69eff,
    primary_hi    = 0xcfbcff,
    on_primary    = 0x2e1065,
    secondary_ctr = 0x4a4458,
    on_surface    = 0xe6e1e5,
    on_var        = 0xcac4d0,
    outline       = 0x938f99,
    green         = 0xd6f26a,
    red           = 0xf2b8b5,
}

-- ─── 中文标签 ─────────────────────────────────────────
local L_MUSIC = "音乐"
local L_PREV  = "上首"
local L_NEXT  = "下首"
local L_REW   = "快退"
local L_FF    = "快进"
local L_PLAY  = "播放"
local L_PAUSE = "暂停"
local L_QUEUE = "播放队列"
local L_VOL   = "音量"
local L_CLOSE = "✕"

local S_READY   = "就绪"
local S_PLAYING = "播放中"
local S_PAUSED  = "已暂停"
local S_STOPPED = "已停止"
local S_NO_ART  = "未知艺术家"
local S_NO_TRK  = "未选择曲目"

local SEEK_STEP = 10

-- ─── 初始化 ───────────────────────────────────────────
function M.init(ctx)
    M.ctx = ctx
    M.visible = false
    M.ready = false
    if not ctx.AUD then return end
    if ctx.AUD.audio_init() ~= 0 then return end
    M.ready = true

    -- 恢复持久化状态
    local S = ctx._music_state or {}
    M.volume = S.volume or 80
    M.scroll = S.scroll or 0
    M.cur    = S.cur or 0
    ctx.AUD.audio_set_volume(M.volume)
    M.toggle_hint = fmt_keybind(ctx, "toggle_music_player")

    -- 行高（优先用主字体避免被 emoji/CJK 撑大）
    local raw_lh = ctx.get_line_height()
    local lh = raw_lh
    if ctx.get_primary_line_height then
        local plh = ctx.get_primary_line_height()
        if plh and plh >= 16 then lh = plh end
    end
    M.LH = lh

    -- 尺寸
    M.PAD     = 24
    M.W       = math.min(ctx.scr_w - 80, 920)
    M.COVER   = 96
    M.CTRL_H  = lh + 28
    M.APPBAR  = lh + 30
    M.SECT_H  = lh + 16
    M.ROW_H   = lh + 22
    M.BOTBAR  = lh + 20

    -- 信息区高度
    M.INFO_H = 20 + M.COVER + 16 + 6 + (lh + 4) + 12 + M.CTRL_H + 20

    local top_h = M.APPBAR + M.INFO_H + M.SECT_H
    M.HMAX  = math.min(ctx.scr_h - 120, 700)
    M.VROWS = math.max(3, math.floor((M.HMAX - top_h - M.BOTBAR) / M.ROW_H))
    M.H     = top_h + M.VROWS * M.ROW_H + M.BOTBAR
    M.X     = math.floor((ctx.scr_w - M.W) / 2)
    M.YH    = -(M.H + 4)
    M.YS    = 0

    -- 控制按钮宽度（根据标签宽度计算）
    local function tw(s) return select(1, ctx.get_text_size(s)) end
    local wmax = math.max(tw(L_PREV), tw(L_REW), tw(L_PLAY), tw(L_FF), tw(L_NEXT))
    M.BTN_W = wmax + 40
    M.BTN_GAP = 16

    -- 播放列表
    M.playlist = scan(ctx.config.audio_panel_dir, ctx.AUD)
    M.playing  = false
    M.paused   = false
    M.pos      = 0
    M.dur      = 0
    M.redraw   = false
    M.poll     = 0
    M.probe    = 1
    M.anim_y   = M.YH
    M.target_y = M.YH

    -- Surface + UI
    M.surf = Surface.new(ctx, M.W, M.H)
    M.ui = UI.new(ctx, THEME)
    M.ui:attach(M.surf)

    -- Canvas 窗口
    M.canvas = ctx.create_canvas(M.W, M.H, {
        x = M.X, y = M.YH, bg = THEME.bg, border = THEME.bg, border_width = 1,
    })

    ctx.register_action("toggle_music_player", function() M.toggle() end)
    ctx.on("tick",   function(dt) M.tick(dt) end)
    ctx.on("xevent", function(t, ev) M.on_ev(t, ev) end)

    log("ready: %d tracks, %dx%d lh=%d", #M.playlist, M.W, M.H, lh)
end

-- ─── 显示/隐藏 ────────────────────────────────────────
function M.show()
    M.anim_y   = M.YH
    M.target_y = M.YS
    M.canvas:move(M.X, math.floor(M.anim_y))
    M.draw()
    M.canvas:show()
    M.visible = true
end

function M.hide()
    M.target_y = M.YH
    M.visible  = false
end

function M.toggle()
    if not M.ready then
        M.ctx.show_bubble("音频不可用 😢")
        return
    end
    if M.visible then M.hide() else M.show() end
end

-- ─── 播放控制 ─────────────────────────────────────────
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

function M.seek_rel(delta)
    if M.dur <= 0 then return end
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

-- ─── 布局 ─────────────────────────────────────────────
local function LAYOUT(M)
    local lh  = M.LH
    local PAD = M.PAD

    local app_h  = M.APPBAR
    local info_y = app_h
    local sect_y = info_y + M.INFO_H
    local list_y = sect_y + M.SECT_H
    local bot_y  = M.H - M.BOTBAR

    -- 信息区内部
    local cover_x = PAD
    local cover_y = info_y + 20
    local info_x  = cover_x + M.COVER + 20
    local info_w  = M.W - info_x - PAD

    local prog_x = PAD
    local prog_y = cover_y + M.COVER + 16
    local prog_w = M.W - PAD * 2
    local prog_h = 6

    local time_y = prog_y + prog_h + 4
    local ctrl_y = time_y + lh + 8
    local ctrl_h = M.CTRL_H

    -- 控制按钮居中
    local total_w = M.BTN_W * 5 + M.BTN_GAP * 4
    local btn_x0  = math.floor((M.W - total_w) / 2)

    return {
        app_h = app_h,
        info_y = info_y,
        sect_y = sect_y,
        sect_h = M.SECT_H,
        list_y = list_y,
        list_end = bot_y,
        bot_y = bot_y,
        bot_h = M.BOTBAR,

        cover_x = cover_x, cover_y = cover_y, cover_sz = M.COVER,
        info_x = info_x, info_w = info_w,

        prog_x = prog_x, prog_y = prog_y, prog_w = prog_w, prog_h = prog_h,
        time_y = time_y,

        ctrl_y = ctrl_y, ctrl_h = ctrl_h,
        btn_x0 = btn_x0, btn_w = M.BTN_W, btn_gap = M.BTN_GAP,
    }
end
M.LAYOUT = LAYOUT

-- ─── 事件 ─────────────────────────────────────────────
function M.on_ev(t, ev)
    if not M.ready or not M.canvas or not M.visible then return end

    -- 过滤：只处理本窗口的事件
    local from_us = false
    if t == 4 or t == 5 then
        from_us = (ev.xbutton.window == M.canvas.win)
    elseif t == 6 then
        from_us = (ev.xmotion.window == M.canvas.win)
    elseif t == 12 then
        from_us = (ev.xexpose.window == M.canvas.win)
    end
    if not from_us then return end

    M.ui:on_event(t, ev)
    M.redraw = true

    -- 滚轮滚动列表
    if t == 4 then
        local l = LAYOUT(M)
        if ev.xbutton.y >= l.list_y and ev.xbutton.y < l.list_end then
            if ev.xbutton.button == 4 then
                M.scroll = math.max(0, M.scroll - 1)
            elseif ev.xbutton.button == 5 then
                local mx = math.max(0, #M.playlist - M.VROWS)
                M.scroll = math.min(mx, M.scroll + 1)
            end
        end
    end
end

-- ─── Tick ─────────────────────────────────────────────
function M.tick(dt)
    if not M.ready or not M.canvas then return end

    -- 下拉动画
    if M.anim_y ~= M.target_y then
        local d = M.target_y - M.anim_y
        if math.abs(d) < 1.5 then
            M.anim_y = M.target_y
        else
            M.anim_y = M.anim_y + d * 0.3
        end
        M.canvas:move(M.X, math.floor(M.anim_y))
        if M.anim_y == M.target_y and M.target_y < 0 then
            M.canvas:hide()
            return
        end
    end

    if not M.visible then return end

    local A = M.ctx.AUD

    -- 自动下一首
    if A.audio_finished() == 1 and #M.playlist > 0 then
        M.next()
    end

    -- 定期轮询
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

    -- 懒加载时长探测
    if M.probe <= #M.playlist then
        local it = M.playlist[M.probe]
        if not it.duration then
            local d = A.audio_probe_duration(it.path)
            if d and d > 0 then it.duration = d end
            M.redraw = true
        end
        M.probe = M.probe + 1
    end

    if M.redraw then
        M.draw()
        M.redraw = false
    end
end

-- ─── 绘制 ─────────────────────────────────────────────
function M.draw()
    if not M.surf then return end
    local ui, s, T = M.ui, M.surf, M.ui.theme
    local lh = M.LH
    local l = LAYOUT(M)
    local tw = function(str) return select(1, M.ctx.get_text_size(str)) end

    s:clear(T.bg)
    ui:begin()

    -- ═══════ 顶部栏 ═══════
    s:rect(0, 0, M.W, l.app_h, T.surface)
    local ay = math.floor((l.app_h - lh) / 2)

    local mus_w = tw(L_MUSIC)
    s:text(M.PAD, ay, L_MUSIC, T.primary)

    local cur = (M.cur > 0) and M.playlist[M.cur] or nil
    local sub = cur and cur.title or "—"
    s:text(M.PAD + mus_w + 16, ay, truncate(sub, 40), T.on_var)

    -- 快捷键提示 + 关闭按钮
    local close_sz = 32
    local close_x = M.W - M.PAD - close_sz
    local close_y = math.floor((l.app_h - close_sz) / 2)
    local hint_w = tw(M.toggle_hint)
    s:text(close_x - 16 - hint_w, ay, M.toggle_hint, T.outline)

    local close_hover = ui:hover(close_x, close_y, close_sz, close_sz)
    s:rrect(close_x, close_y, close_sz, close_sz,
            math.floor(close_sz / 2),
            close_hover and T.surface_hi or T.bg)
    local cl_w = tw(L_CLOSE)
    s:text(math.floor(close_x + close_sz / 2 - cl_w / 2),
           math.floor(close_y + (close_sz - lh) / 2), L_CLOSE, T.red)

    if ui:clicked(close_x, close_y, close_sz, close_sz) then
        M.hide()
    end

    s:rect(0, l.app_h - 1, M.W, 1, T.outline)

    -- ═══════ 信息区 ═══════
    -- 封面
    s:rrect(l.cover_x, l.cover_y, l.cover_sz, l.cover_sz, 20, T.surface_hi)
    local g_ts = "♪"
    local gw = tw(g_ts)
    s:text(math.floor(l.cover_x + l.cover_sz / 2 - gw / 2),
           math.floor(l.cover_y + l.cover_sz / 2 - lh / 2),
           g_ts, T.primary)

    -- 标题 + 艺术家
    local title = cur and cur.title or S_NO_TRK
    s:text(l.info_x, l.cover_y + 8, truncate(title, 48), T.on_surface)
    s:text(l.info_x, l.cover_y + 8 + lh + 6, cur and S_NO_ART or "", T.on_var)

    -- 进度滑块
    if M.dur > 0 then
        local new_pos, changed = ui:slider("mp_prog",
            l.prog_x, l.prog_y, l.prog_w, M.pos,
            { min = 0, max = M.dur, track = T.surface_hi,
              color = T.primary, handle = T.on_surface })
        if changed then
            M.pos = new_pos
            M.ctx.AUD.audio_seek(M.pos)
        end
    else
        -- 无曲目：空轨道
        s:rrect(l.prog_x, l.prog_y, l.prog_w, 6, 3, T.surface_hi)
    end

    -- 时间行
    s:text(l.prog_x, l.time_y, fmt_time(M.pos), T.on_var)
    local dur_str = fmt_time(M.dur)
    local dur_w = tw(dur_str)
    s:text(l.prog_x + l.prog_w - dur_w, l.time_y, dur_str, T.on_var)

    -- 控制按钮
    local btns = {
        { "prev", L_PREV, false },
        { "rew",  L_REW,  false },
        { "play", (M.playing and not M.paused) and L_PAUSE or L_PLAY, true },
        { "ff",   L_FF,   false },
        { "next", L_NEXT, false },
    }
    for i, item in ipairs(btns) do
        local bx = l.btn_x0 + (i - 1) * (l.btn_w + l.btn_gap)
        if ui:id_button("mp_" .. item[1], bx, l.ctrl_y, l.btn_w, l.ctrl_h,
                        item[2], { filled = item[3] }) then
            local k = item[1]
            if k == "prev" then M.prev()
            elseif k == "rew"  then M.seek_rel(-SEEK_STEP)
            elseif k == "play" then M.toggle_pause()
            elseif k == "ff"   then M.seek_rel(SEEK_STEP)
            elseif k == "next" then M.next() end
        end
    end

    -- ═══════ 分区标题 ═══════
    s:rect(0, l.sect_y, M.W, l.sect_h, T.bg)
    local sy = l.sect_y + math.floor((l.sect_h - lh) / 2)
    s:text(M.PAD, sy, L_QUEUE, T.primary)
    local cnt = string.format("%d / %d", M.cur, #M.playlist)
    local cnt_w = tw(cnt)
    s:text(M.W - M.PAD - cnt_w, sy, cnt, T.outline)
    s:rect(0, l.sect_y + l.sect_h - 1, M.W, 1, T.outline)

    -- ═══════ 列表 ═══════
    local mx = math.max(0, #M.playlist - M.VROWS)
    if M.scroll > mx then M.scroll = mx end

    for i = 1, M.VROWS do
        local idx = M.scroll + i
        if idx > #M.playlist then break end
        local ry = l.list_y + (i - 1) * M.ROW_H
        local it = M.playlist[idx]
        local sel = (idx == M.cur)
        local row_bg = sel and T.surface_hi or T.bg

        s:rect(0, ry, M.W, M.ROW_H, row_bg)
        if sel then s:rect(0, ry, 4, M.ROW_H, T.primary) end

        -- 数字徽章
        local bsz = 28
        local bcy = ry + math.floor((M.ROW_H - bsz) / 2)
        local badge_bg = sel and T.primary or T.surface_hi
        local badge_fg = sel and T.on_primary or T.on_var
        s:rrect(M.PAD, bcy, bsz, bsz, 8, badge_bg)
        local num_str = string.format("%d", idx)
        local nw = tw(num_str)
        s:text(math.floor(M.PAD + bsz / 2 - nw / 2),
               math.floor(bcy + (bsz - lh) / 2), num_str, badge_fg)

        -- 标题
        local tx = M.PAD + bsz + 16
        local ty = ry + math.floor((M.ROW_H - lh) / 2)
        s:text(tx, ty, truncate(it.title, 60),
               sel and T.on_surface or T.on_var)

        -- 时长
        if it.duration then
            local ds = fmt_time(it.duration)
            local dw = tw(ds)
            s:text(M.W - M.PAD - dw, ty, ds, T.outline)
        end

        -- 分隔线
        if i < M.VROWS and idx < #M.playlist then
            s:rect(M.PAD, ry + M.ROW_H - 1, M.W - M.PAD * 2, 1, T.outline)
        end

        -- 行点击
        if ui:clicked(0, ry, M.W, M.ROW_H) then
            M.play_idx(idx)
        end
    end

    -- 滚动条
    if mx > 0 then
        local track_h = M.VROWS * M.ROW_H
        local bh = math.max(32, math.floor(track_h * M.VROWS / #M.playlist))
        local by = l.list_y + math.floor((track_h - bh) * M.scroll / mx)
        s:rrect(M.W - 6, by, 4, bh, 2, T.outline)
    end

    -- ═══════ 底部栏 ═══════
    s:rect(0, l.bot_y, M.W, l.bot_h, T.surface)
    s:rect(0, l.bot_y, M.W, 1, T.outline)
    local bty = l.bot_y + math.floor((l.bot_h - lh) / 2)

    -- 状态
    local status, dot_col
    if M.cur == 0 then
        status = S_READY
    elseif M.paused then
        status = S_PAUSED
    elseif M.playing then
        status = S_PLAYING
    else
        status = S_STOPPED
    end
    dot_col = (M.playing and not M.paused) and T.green or T.outline
    s:rrect(M.PAD, bty + math.floor(lh / 2) - 4, 8, 8, 4, dot_col)
    s:text(M.PAD + 20, bty, status, T.on_var)

    -- 音量
    local pct_str = string.format("%d%%", M.volume)
    local pct_w = tw(pct_str)
    local vol_w = 100
    local vol_x = M.W - M.PAD - pct_w - 12 - vol_w
    local vol_lbl_w = tw(L_VOL)
    s:text(vol_x - 12 - vol_lbl_w, bty, L_VOL, T.on_var)

    local new_vol, changed = ui:slider("mp_vol",
        vol_x, bty + math.floor(lh / 2) - 2, vol_w, M.volume,
        { min = 0, max = 100, track = T.surface_hi,
          color = T.green, handle = T.on_surface })
    if changed then M.set_volume_pct(new_vol) end

    s:text(M.W - M.PAD - pct_w, bty, pct_str, T.on_var)

    ui:end_frame()
    s:flush(M.canvas.win, M.canvas.wgc, 0, 0)
end

function M.shutdown()
    if M.ctx then
        M.ctx._music_state = {
            volume = M.volume,
            scroll = M.scroll,
            cur    = M.cur,
        }
    end
    if M.surf then M.surf:destroy() end
    if M.canvas then M.canvas:destroy() end
    M.ready = false
end

return M