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

-- 分组展示：组内按 config.keybinds 的声明顺序排列，未归类的进「其他」
local GROUPS = {
    { title = "宠物",  actions = { "toggle_chase", "toggle_freeze", "say_hello" } },
    { title = "面板",  actions = { "show_keybinds_help", "toggle_music_player", "toggle_weather",
                                   "toggle_sysinfo", "toggle_sysmon", "toggle_pomodoro",
                                   "toggle_clip_hist", "toggle_launcher", "toggle_color_picker" } },
    { title = "系统",  actions = { "hot_reload", "toggle_auto_reload", "quit" } },
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
    M.ROW_H = lh + 12
    M.SEC_H = lh + 14
    M.GAP = 10
    M.PAD = 24
    M.COMBO_COL = 180

    -- action -> kb 索引
    local by_action = {}
    local seen = {}
    for _, kb in ipairs(ctx.config.keybinds or {}) do
        if not by_action[kb.action] then
            by_action[kb.action] = kb
        end
    end

    M.groups = {}
    local used = {}
    local H_content = 0
    for _, g in ipairs(GROUPS) do
        local rows = {}
        for _, act in ipairs(g.actions) do
            local kb = by_action[act]
            if kb and not used[act] then
                used[act] = true
                rows[#rows + 1] = { combo = combo_of(kb), desc = DESCR[act] or act }
            end
        end
        if #rows > 0 then
            M.groups[#M.groups + 1] = { title = g.title, rows = rows }
            H_content = H_content + M.SEC_H + #rows * M.ROW_H + M.GAP
        end
    end
    local rest = {}
    for _, kb in ipairs(ctx.config.keybinds or {}) do
        if not used[kb.action] then
            used[kb.action] = true
            rest[#rest + 1] = { combo = combo_of(kb), desc = DESCR[kb.action] or kb.action }
        end
    end
    if #rest > 0 then
        M.groups[#M.groups + 1] = { title = "其他", rows = rest }
        H_content = H_content + M.SEC_H + #rest * M.ROW_H + M.GAP
    end

    M.H = M.APPBAR + 12 + H_content + 14

    M.panel = Panel.new(ctx, {
        name = 'keybinds_help',
        w = M.W,
        h = M.H,
        theme = THEME,
        draw = function(p) M.draw(p) end,
    })

    ctx.register_action("show_keybinds_help", function() M.panel:toggle() end)
    ctx.on("tick", function(dt) M.panel:tick(dt) end)
    ctx.on("xevent", function(t, ev) return M.on_ev(t, ev) end)
    log("ready: %d keybinds", #(ctx.config.keybinds or {}))
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

    local y = M.APPBAR + 12
    for _, g in ipairs(M.groups) do
        -- 分组标题 + 分隔线
        s:text(M.PAD, y, g.title, T.primary)
        s:rect(M.PAD + tw(g.title) + 12, y + math.floor(lh / 2),
               W - M.PAD * 2 - tw(g.title) - 12, 1, T.outline)
        y = y + M.SEC_H
        for _, row in ipairs(g.rows) do
            local hover = ui:hover(8, y - 4, W - 16, M.ROW_H)
            if hover then
                s:rrect(8, y - 4, W - 16, M.ROW_H, 8, T.surface_hi)
            end
            s:text(M.PAD, y, row.combo, T.primary_hi)
            s:text(M.PAD + M.COMBO_COL, y, row.desc, T.on_surface)
            y = y + M.ROW_H
        end
        y = y + M.GAP
    end
end

return M
