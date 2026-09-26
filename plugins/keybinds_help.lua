local M = {}
local Panel = require("core.panel")
local Util = require("core.util")

local log = Util.logger("keybinds_help")

local THEME = {
    bg            = 0x141218,
    surface       = 0x1d1b20,
    surface_hi    = 0x2b2930,
    primary       = 0xb69eff,
    primary_hi    = 0xcfbcff,
    on_primary    = 0x2e1065,
    secondary_ctr = 0x4a4458,
    on_surface    = 0xe6e1e5,
    on_var        = 0xcac4d0,
    outline       = 0x49454f,
    red           = 0xf2b8b5,
    green         = 0xa6e3a1,
}

local DESCR = {
    toggle_chase         = "宠物追逐鼠标",
    toggle_freeze        = "宠物冻结/恢复",
    quit                 = "退出 xpet",
    say_hello            = "宠物打招呼",
    show_keybinds_help   = "快捷键帮助（本面板）",
    toggle_music_player  = "音乐播放器",
    hot_reload           = "热重载配置与插件",
    toggle_auto_reload   = "自动重载开关",
    toggle_weather       = "天气面板",
    toggle_sysinfo       = "系统信息",
    toggle_sysmon        = "系统监视器",
    toggle_pomodoro      = "番茄钟",
    toggle_clip_hist     = "剪贴板历史",
    toggle_launcher      = "快速启动器",
    toggle_color_picker  = "屏幕取色器",
}

local L_TITLE = "快捷键帮助"
local L_CLOSE = "×"

local function combo_of(kb)
    local parts = {}
    for p in kb.mod:gmatch('[^+]+') do
        parts[#parts + 1] = p:sub(1, 1):upper() .. p:sub(2):lower()
    end
    parts[#parts + 1] = kb.key:upper()
    return table.concat(parts, '+')
end

function M.init(ctx)
    M.ctx = ctx
    local lh = ctx.get_primary_line_height()
    M.LH = lh
    M.W = 420
    M.APPBAR = lh + 30
    M.ROW_H = lh + 14
    M.PAD = 24

    M.rows = {}
    for _, kb in ipairs(ctx.config.keybinds or {}) do
        M.rows[#M.rows + 1] = {
            combo = combo_of(kb),
            desc = DESCR[kb.action] or kb.action,
        }
    end
    M.H = M.APPBAR + 10 + #M.rows * M.ROW_H + 14

    M.panel = Panel.new(ctx, {
        w = M.W,
        h = M.H,
        theme = THEME,
        draw = function(p) M.draw(p) end,
    })

    ctx.register_action("show_keybinds_help", function() M.panel:toggle() end)
    ctx.on("tick", function(dt) M.panel:tick(dt) end)
    ctx.on("xevent", function(t, ev) return M.on_ev(t, ev) end)
    log("ready: %d keybinds", #M.rows)
end

function M.on_ev(t, ev)
    if not M.panel then return false end
    return M.panel:on_ev(t, ev)
end

function M.draw(p)
    local ui, s, T = p.ui, p.surf, p.ui.theme
    local lh = M.LH
    local W = M.W
    local tw = function(str) return select(1, M.ctx.get_text_size(str)) end

    s:rect(0, 0, W, M.APPBAR, T.surface)
    local ay = math.floor((M.APPBAR - lh) / 2)
    s:text(M.PAD, ay, L_TITLE, T.primary)

    local close_sz = 32
    local close_x = W - 24 - close_sz
    local close_y = math.floor((M.APPBAR - close_sz) / 2)
    local close_hover = ui:hover(close_x, close_y, close_sz, close_sz)
    s:rrect(close_x, close_y, close_sz, close_sz,
            math.floor(close_sz / 2), close_hover and T.surface_hi or T.bg)
    local cl_w = tw(L_CLOSE)
    s:text(math.floor(close_x + close_sz / 2 - cl_w / 2),
           math.floor(close_y + (close_sz - lh) / 2), L_CLOSE, T.red)
    if ui:clicked(close_x, close_y, close_sz, close_sz) then
        p:hide()
    end
    s:rect(0, M.APPBAR - 1, W, 1, T.outline)

    local y = M.APPBAR + 10
    for i, row in ipairs(M.rows) do
        local hover = ui:hover(0, y - 4, W, M.ROW_H)
        if hover then
            s:rect(8, y - 4, W - 16, M.ROW_H, T.surface_hi)
        end
        s:text(M.PAD, y, row.combo, i % 2 == 0 and T.primary_hi or T.primary)
        s:text(M.PAD + 170, y, row.desc, T.on_surface)
        y = y + M.ROW_H
    end
end

return M
