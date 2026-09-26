local M = {}
local UI = require("core.ui")
local Surface = require("core.surface")

local function log(fmt, ...)
    io.stderr:write("[sysinfo] " .. string.format(fmt, ...) .. "\n")
end

-- ─── 主题 ───────────────────────────────────────────────
local THEME = {
    bg         = 0x141218,
    surface    = 0x1d1b20,
    surface_hi = 0x2b2930,
    primary    = 0xb69eff,
    primary_hi = 0xcfbcff,
    on_primary = 0x2e1065,
    on_surface = 0xe6e1e5,
    on_var     = 0xcac4d0,
    outline    = 0x49454f,
    green      = 0xa6e3a1,
    warm       = 0xf9e2af,
    blue       = 0x89b4fa,
    red        = 0xf38ba8,
}

local REFRESH_MS = 2000     -- 面板可见时刷新间隔

-- ─── 底层文件读取 ───────────────────────────────────────
local function read_first(p)
    local f = io.open(p, "r")
    if not f then return nil end
    local s = f:read("*l")
    f:close()
    return s
end

local function read_all(p)
    local f = io.open(p, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

-- ─── 数据采集 ───────────────────────────────────────────
local function fmt_bytes(gib)
    if gib >= 1024 then return string.format("%.1f TiB", gib / 1024) end
    return string.format("%.1f GiB", gib)
end

local function fmt_uptime(sec)
    if not sec then return "--" end
    local d = math.floor(sec / 86400)
    local h = math.floor((sec % 86400) / 3600)
    local m = math.floor((sec % 3600) / 60)
    if d > 0 then return string.format("%d天 %d小时 %d分", d, h, m) end
    if h > 0 then return string.format("%d小时 %d分", h, m) end
    return string.format("%d分", m)
end

local function gather(ctx)
    local rows = {}

    -- 主机
    local host = read_first("/proc/sys/kernel/hostname") or "?"
    rows[#rows + 1] = { "主机", host }

    -- 系统
    local osrel = read_all("/etc/os-release") or ""
    local distro = osrel:match('PRETTY_NAME="([^"]+)"') or "Linux"
    rows[#rows + 1] = { "系统", distro }

    -- 内核
    local ver = read_first("/proc/version") or ""
    local kernel = ver:match("Linux version ([%w%.%-_]+)") or "?"
    rows[#rows + 1] = { "内核", kernel }

    -- 桌面环境
    local desktop = os.getenv("XDG_CURRENT_DESKTOP") or
                    os.getenv("DESKTOP_SESSION") or "--"
    rows[#rows + 1] = { "桌面", desktop }

    -- Shell
    local shell = os.getenv("SHELL") or "?"
    shell = shell:match("([^/]+)$") or shell
    rows[#rows + 1] = { "Shell", shell }

    -- 用户
    rows[#rows + 1] = { "用户", os.getenv("USER") or "?" }

    -- 分隔
    rows[#rows + 1] = { sep = true }

    -- CPU
    local cpuinfo = read_all("/proc/cpuinfo") or ""
    local model = cpuinfo:match("model name%s*:%s*([^\n]+)") or "?"
    local mhz   = cpuinfo:match("cpu MHz%s*:%s*([%d%.]+)")
    if mhz then
        model = model .. string.format(" @ %.2f GHz", tonumber(mhz) / 1000)
    end
    rows[#rows + 1] = { "CPU", model }

    -- 负载
    local la = read_first("/proc/loadavg") or ""
    local l1, l5, l15 = la:match("([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)")
    if l1 then
        rows[#rows + 1] = { "负载", string.format("%s  %s  %s", l1, l5, l15) }
    end

    -- 内存
    local mi = read_all("/proc/meminfo") or ""
    local function mem_kb(k)
        return tonumber(mi:match(k .. ":%s*(%d+)"))
    end
    local total_kb = mem_kb("MemTotal")
    local avail_kb = mem_kb("MemAvailable")
    if total_kb and avail_kb then
        local used_kb = total_kb - avail_kb
        local total_gib = total_kb / 1024 / 1024
        local used_gib  = used_kb  / 1024 / 1024
        local pct = math.floor(used_kb / total_kb * 100)
        rows[#rows + 1] = {
            "内存",
            string.format("%s / %s  (%d%%)",
                          fmt_bytes(used_gib), fmt_bytes(total_gib), pct),
        }
    end

    -- 运行时间
    local ut = read_first("/proc/uptime")
    local uptime_sec = ut and tonumber(ut:match("([%d%.]+)"))
    rows[#rows + 1] = { "运行", fmt_uptime(uptime_sec) }

    -- 显示分辨率
    rows[#rows + 1] = { "分辨率", string.format("%dx%d", ctx.scr_w, ctx.scr_h) }

    return rows
end

-- ─── 插件主体 ───────────────────────────────────────────
function M.init(ctx)
    M.ctx     = ctx
    M.ready   = true
    M.visible = false

    local lh = ctx.get_primary_line_height()
    M.LH  = lh
    M.PAD = 22
    M.W   = 520

    -- 高度：行数 × 行高 + 顶栏 + 底栏
    -- 先采一次数据估算行数
    local sample = gather(ctx)
    local n_rows = 0
    for _, r in ipairs(sample) do
        n_rows = n_rows + (r.sep and 1 or 1)
    end
    local header_h = lh + 20
    local footer_h = lh + 16
    local row_h    = lh + 6
    M.H = header_h + row_h * n_rows + footer_h + 32

    M.X        = math.floor((ctx.scr_w - M.W) / 2)
    M.Y_SHOWN  = math.floor((ctx.scr_h - M.H) / 2)
    M.Y_HIDDEN = -(M.H + 4)

    M.rows        = sample
    M.need_redraw = true
    M.anim_y      = M.Y_HIDDEN
    M.target_y    = M.Y_HIDDEN
    M.refresh_acc = 0

    M.surf = Surface.new(ctx, M.W, M.H)
    M.ui   = UI.new(ctx, THEME)
    M.ui:attach(M.surf)

    M.canvas = ctx.create_canvas(M.W, M.H, {
        x = M.X, y = M.Y_HIDDEN,
        bg = THEME.bg, border = THEME.bg, border_width = 1,
    })

    ctx.register_action("toggle_sysinfo", function() M.toggle() end)
    ctx.on("tick",   function(dt) M.tick(dt) end)
    ctx.on("xevent", function(t, ev) M.on_ev(t, ev) end)

    log("ready")
end

function M.toggle()
    if not M.ready then return end
    M.visible = not M.visible
    if M.visible then
        M.rows     = gather(M.ctx)
        M.anim_y   = M.Y_HIDDEN
        M.target_y = M.Y_SHOWN
        M.canvas:move(M.X, math.floor(M.anim_y))
        M.canvas:show()
        M.draw()
    else
        M.target_y = M.Y_HIDDEN
    end
end

function M.on_ev(t, ev)
    if not M.ready or not M.visible then return end
    local mine = false
    if t == 4 or t == 5 then
        mine = (ev.xbutton.window == M.canvas.win)
    elseif t == 6 then
        mine = (ev.xmotion.window == M.canvas.win)
    elseif t == 12 then
        mine = (ev.xexpose.window == M.canvas.win)
    end
    if not mine then return end

    M.ui:on_event(t, ev)
    if t == 12 then M.draw() end
end

function M.tick(dt_ms)
    if not M.ready then return end

    -- 下拉/上滑动画
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

    -- 每 2 秒刷新一次数据（纯文件读取，无 IO 阻塞）
    M.refresh_acc = M.refresh_acc + dt_ms
    if M.refresh_acc >= REFRESH_MS then
        M.refresh_acc = 0
        M.rows = gather(M.ctx)
        M.draw()
    end
end

-- ─── 绘制 ───────────────────────────────────────────────
function M.draw()
    if not M.surf then return end
    local ui, s, T = M.ui, M.surf, M.ui.theme
    local lh, PAD = M.LH, M.PAD

    s:clear(T.bg)
    ui:begin()

    -- 顶栏
    local header_h = lh + 20
    s:rect(0, 0, M.W, header_h, T.surface)
    local hy = math.floor((header_h - lh) / 2)
    s:text(PAD, hy, "系统信息", T.primary)

    local hint = "Ctrl+Alt+I"
    local hw   = select(1, M.ctx.get_text_size(hint))
    s:text(M.W - PAD - hw, hy, hint, T.outline)
    s:rect(0, header_h - 1, M.W, 1, T.outline)

    -- 计算标签列宽度（动态，取所有标签宽度的最大值 + 40）
    local label_w = 0
    for _, r in ipairs(M.rows) do
        if not r.sep then
            local w = select(1, M.ctx.get_text_size(r[1]))
            if w > label_w then label_w = w end
        end
    end
    label_w = label_w + 36
    local value_x = PAD + label_w

    -- 内容行
    local y = header_h + 14
    local row_h = lh + 6
    for _, r in ipairs(M.rows) do
        if r.sep then
            s:rect(PAD, y + math.floor(row_h / 2) - 1,
                   M.W - PAD * 2, 1, T.outline)
            y = y + row_h
        else
            local tw = select(1, M.ctx.get_text_size(r[2]))
            local max_w = M.W - value_x - PAD
            local value = r[2]
            if tw > max_w then
                -- 简单截断
                local cut = #value
                while cut > 0 do
                    local sub = value:sub(1, cut)
                    if select(1, M.ctx.get_text_size(sub .. "…")) <= max_w then
                        value = sub .. "…"
                        break
                    end
                    cut = cut - 1
                end
            end
            s:text(PAD,     y, r[1], T.outline)
            s:text(value_x, y, value, T.on_surface)
            y = y + row_h
        end
    end

    -- 底栏
    local by = M.H - lh - 12
    s:rect(PAD, by - 8, M.W - PAD * 2, 1, T.outline)

    local src = "procfs"
    s:text(PAD, by, "实时刷新 · 2 秒", T.outline)
    local sw = select(1, M.ctx.get_text_size(src))
    s:text(M.W - PAD - sw, by, src, T.outline)

    ui:end_frame()
    s:flush(M.canvas.win, M.canvas.wgc, 0, 0)
end

function M.shutdown()
    M.ready = false
    if M.surf   then M.surf:destroy() end
    if M.canvas then M.canvas:destroy() end
end

return M