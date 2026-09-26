local M = {}
local Panel = require('core.panel')
local Util = require('core.util')

local log = Util.logger('sysinfo')

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

local REFRESH_MS = 2000

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

    local host = read_first("/proc/sys/kernel/hostname") or "?"
    rows[#rows + 1] = { "主机", host }

    local osrel = read_all("/etc/os-release") or ""
    local distro = osrel:match('PRETTY_NAME="([^"]+)"') or "Linux"
    rows[#rows + 1] = { "系统", distro }

    local ver = read_first("/proc/version") or ""
    local kernel = ver:match("Linux version ([%w%.%-_]+)") or "?"
    rows[#rows + 1] = { "内核", kernel }

    local desktop = os.getenv("XDG_CURRENT_DESKTOP") or
                    os.getenv("DESKTOP_SESSION") or "--"
    rows[#rows + 1] = { "桌面", desktop }

    local shell = os.getenv("SHELL") or "?"
    shell = shell:match("([^/]+)$") or shell
    rows[#rows + 1] = { "Shell", shell }

    rows[#rows + 1] = { "用户", os.getenv("USER") or "?" }

    rows[#rows + 1] = { sep = true }

    local cpuinfo = read_all("/proc/cpuinfo") or ""
    local model = cpuinfo:match("model name%s*:%s*([^\n]+)") or "?"
    local mhz   = cpuinfo:match("cpu MHz%s*:%s*([%d%.]+)")
    if mhz then
        model = model .. string.format(" @ %.2f GHz", tonumber(mhz) / 1000)
    end
    rows[#rows + 1] = { "CPU", model }

    local la = read_first("/proc/loadavg") or ""
    local l1, l5, l15 = la:match("([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)")
    if l1 then
        rows[#rows + 1] = { "负载", string.format("%s  %s  %s", l1, l5, l15) }
    end

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

    local ut = read_first("/proc/uptime")
    local uptime_sec = ut and tonumber(ut:match("([%d%.]+)"))
    rows[#rows + 1] = { "运行", fmt_uptime(uptime_sec) }

    rows[#rows + 1] = { "分辨率", string.format("%dx%d", ctx.scr_w, ctx.scr_h) }

    return rows
end

function M.init(ctx)
    M.ctx     = ctx
    M.ready   = true

    local lh = ctx.get_primary_line_height()
    M.LH  = lh
    M.PAD = 22
    M.W   = 520

    local sample = gather(ctx)
    local n_rows    = #sample
    local header_h  = lh + 20
    local footer_h  = lh + 16
    local row_h     = lh + 6
    M.H = header_h + row_h * n_rows + footer_h + 32

    M.rows        = sample
    M.refresh_acc = 0

    M.panel = Panel.new(ctx, {
        w = M.W, h = M.H,
        theme = THEME,
        draw = function(p) M.draw(p) end,
        on_show = function()
            M.rows = gather(ctx)
        end,
        tick = function(p, dt)
            M.refresh_acc = M.refresh_acc + dt
            if M.refresh_acc >= REFRESH_MS then
                M.refresh_acc = 0
                M.rows = gather(ctx)
                p:draw()
            end
        end,
    })

    ctx.register_action("toggle_sysinfo", function() M.toggle() end)
    ctx.on("tick",   function(dt) M.tick(dt) end)
    ctx.on("xevent", function(t, ev) return M.on_ev(t, ev) end)

    log("ready")
end

function M.toggle()
    if not M.ready then return end
    M.panel:toggle()
end

function M.on_ev(t, ev)
    if not M.ready then return false end
    return M.panel:on_ev(t, ev)
end

function M.tick(dt)
    if not M.ready then return end
    M.panel:tick(dt)
end

function M.draw(p)
    if not p.surf then return end
    local ui, s, T = p.ui, p.surf, p.ui.theme
    local lh, PAD = M.LH, M.PAD

    local header_h = lh + 20
    s:rect(0, 0, M.W, header_h, T.surface)
    local hy = math.floor((header_h - lh) / 2)
    s:text(PAD, hy, "系统信息", T.primary)

    local hint = "Ctrl+Alt+I"
    local hw   = select(1, M.ctx.get_text_size(hint))
    s:text(M.W - PAD - hw, hy, hint, T.outline)
    s:rect(0, header_h - 1, M.W, 1, T.outline)

    local label_w = 0
    for _, r in ipairs(M.rows) do
        if not r.sep then
            local w = select(1, M.ctx.get_text_size(r[1]))
            if w > label_w then label_w = w end
        end
    end
    label_w = label_w + 36
    local value_x = PAD + label_w

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

    local by = M.H - lh - 12
    s:rect(PAD, by - 8, M.W - PAD * 2, 1, T.outline)

    local src = "procfs"
    s:text(PAD, by, "实时刷新 · 2 秒", T.outline)
    local sw = select(1, M.ctx.get_text_size(src))
    s:text(M.W - PAD - sw, by, src, T.outline)
end

function M.shutdown()
    M.ready = false
    if M.panel then M.panel:destroy() end
end

return M
