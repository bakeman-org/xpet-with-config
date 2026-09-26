local M = {}
local UI = require("core.ui")
local Surface = require("core.surface")
local ffi = require("ffi")

local function log(fmt, ...)
    io.stderr:write("[weather] " .. string.format(fmt, ...) .. "\n")
end

local REFRESH_SEC   = 900      -- 15 分钟自动刷新
local CURL_TIMEOUT  = 8        -- 单次 curl 超时
local POLL_MS       = 1500     -- 输出文件轮询间隔
local REDRAW_MS     = 5000     -- 最小重绘间隔

-- 硬编码兜底城市：所有定位手段都失败时用它
local FALLBACK_CITY = "Beijing"

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
    green      = 0xd6f26a,
    red        = 0xf2b8b5,
    warm       = 0xf9e2af,
    blue       = 0x89b4fa,
}

-- 天气图标映射（用中文字，避免依赖 Noto Symbols 字体）
local function icon_for(desc)
    if not desc then return "·" end
    local d = desc:lower()
    if d:find("thunder") or d:find("storm")                   then return "雷" end
    if d:find("snow") or d:find("sleet") or d:find("ice")     then return "雪" end
    if d:find("rain") or d:find("drizzle") or d:find("shower")then return "雨" end
    if d:find("fog") or d:find("mist") or d:find("haze")      then return "雾" end
    if d:find("cloud") or d:find("overcast")                  then return "云" end
    if d:find("sun") or d:find("clear")                       then return "晴" end
    return "云"
end

-- ─── JSON 字段提取（正则，无完整解析器）────────────────
local function extract_scalar(text, name)
    local v = text:match('"' .. name .. '"%s*:%s*"([^"]*)"')
    if v then return v end
    return text:match('"' .. name .. '"%s*:%s*([%-%d%.]+)')
end

local function extract_array_value(text, name)
    return text:match('"' .. name .. '"%s*:%s*%[%s*{%s*"value"%s*:%s*"([^"]*)"')
end

local function parse_weather(text)
    if not text or #text < 20 then return nil end
    if not text:find('"current_condition"', 1, true) then return nil end

    local w = {
        temp      = tonumber(extract_scalar(text, "temp_C"))        or 0,
        feels     = tonumber(extract_scalar(text, "FeelsLikeC"))    or 0,
        humidity  = tonumber(extract_scalar(text, "humidity"))      or 0,
        wind_kmph = tonumber(extract_scalar(text, "windspeedKmph")) or 0,
        wind_dir  = extract_scalar(text, "winddir16Point"),
        desc      = extract_array_value(text, "weatherDesc"),
        city      = extract_array_value(text, "areaName"),
        region    = extract_array_value(text, "region"),
        country   = extract_array_value(text, "country"),
    }
    if not w.wind_dir then
        w.wind_dir = extract_array_value(text, "winddir16Point")
    end
    return w
end

-- ─── 文件工具 ────────────────────────────────────────────
local function state_path()   return "/tmp/xpet-weather-auto.json"      end
local function city_path()    return "/tmp/xpet-weather-city.txt"       end
local function script_path()  return "/tmp/xpet-weather-fetch.sh"       end

local function file_mtime(p)
    local f = io.popen(string.format("stat -c %%Y '%s' 2>/dev/null", p))
    if not f then return 0 end
    local m = tonumber(f:read("*l") or "0") or 0
    f:close()
    return m
end

local function read_file(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

-- ─── 异步抓取：手动指定 > ip-api.com 自动 > fallback ───
-- 全部写在临时 shell 脚本里，一次后台执行，主循环不阻塞。
local function fetch_async(manual_city)
    local out = state_path()
    local cty = city_path()
    local scr = script_path()
    os.remove(out)

    -- 优先级 1：config 里有 manual_city 就直接用
    local pre = ""
    if manual_city and manual_city ~= "" then
        pre = string.format("CITY=%s\n", "'" .. manual_city:gsub("'", "'\\''") .. "'")
    else
        -- 优先级 2：ip-api.com 自动定位（免费 45次/分钟）
        -- 失败则回退到 FALLBACK_CITY
        pre = string.format([[
CITY=$(curl -sS --max-time 5 'http://ip-api.com/json/?fields=city' 2>/dev/null \
  | sed -n 's/.*"city":"\([^"]*\)".*/\1/p')
[ -z "$CITY" ] && CITY=%s
]], "'" .. FALLBACK_CITY .. "'")
    end

    -- 城市名里的空格转成 + 后交给 wttr.in
    local body = pre .. string.format([[
CITY_URL=$(printf '%%s' "$CITY" | sed 's/ /+/g')
printf '%%s' "$CITY" > %s
curl -sS --max-time %d -A 'xpet-weather/1.0' \
  "https://wttr.in/$CITY_URL?format=j1" -o %s 2>/dev/null
]], "'" .. cty .. "'", CURL_TIMEOUT, "'" .. out .. "'")

    -- 写脚本 + 后台执行
    local f = io.open(scr, "w")
    if not f then return end
    f:write("#!/bin/sh\n")
    f:write(body)
    f:close()
    os.execute("sh " .. scr .. " >/dev/null 2>&1 &")
end

-- ─── 插件主体 ────────────────────────────────────────────
function M.init(ctx)
    M.ctx     = ctx
    M.ready   = true
    M.visible = false

    local wcfg = ctx.config.weather or {}
    M.units        = wcfg.units or "c"
    M.refresh_sec  = wcfg.refresh_sec or REFRESH_SEC
    -- 用户手动指定城市：设置后跳过自动定位
    M.manual_city  = wcfg.manual_city

    local lh = ctx.get_primary_line_height()
    M.LH  = lh
    M.PAD = 20
    M.W   = 360
    M.H   = lh * 8 + 72

    M.X        = math.floor((ctx.scr_w - M.W) / 2)
    M.Y_SHOWN  = 0
    M.Y_HIDDEN = -(M.H + 4)

    M.data          = nil
    M.error         = nil
    M.last_mtime    = 0
    M.last_fetch_t  = -1e9
    M.last_update_t = -1e9
    M.pending_notify= false
    M.need_redraw   = true
    M.poll_accum    = 0
    M.redraw_accum  = REDRAW_MS
    M.anim_y        = M.Y_HIDDEN
    M.target_y      = M.Y_HIDDEN

    M.surf = Surface.new(ctx, M.W, M.H)
    M.ui   = UI.new(ctx, THEME)
    M.ui:attach(M.surf)

    M.canvas = ctx.create_canvas(M.W, M.H, {
        x = M.X, y = M.Y_HIDDEN,
        bg = THEME.bg, border = THEME.bg, border_width = 1,
    })

    ctx.register_action("toggle_weather", function() M.toggle() end)
    ctx.on("tick",   function(dt) M.tick(dt) end)
    ctx.on("xevent", function(t, ev) M.on_ev(t, ev) end)

    M:refresh(true, false)   -- 启动时静默刷新一次
    log("ready (manual=%s)", tostring(M.manual_city) or "auto")
end

function M:refresh(force, notify)
    local now = os.time()
    if not force and (now - self.last_fetch_t) < self.refresh_sec then
        return
    end
    self.last_fetch_t = now
    if notify then self.pending_notify = true end
    fetch_async(self.manual_city)
end

function M.toggle()
    if not M.ready then return end
    M.visible = not M.visible
    if M.visible then
        M.anim_y   = M.Y_HIDDEN
        M.target_y = M.Y_SHOWN
        M.canvas:move(M.X, math.floor(M.anim_y))
        M.canvas:show()
        M:refresh(true, true)   -- 打开面板：强制刷新 + 完成时弹 toast
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

    M.poll_accum   = M.poll_accum   + dt_ms
    M.redraw_accum = M.redraw_accum + dt_ms

    -- 轮询输出文件：mtime 变了才重新解析
    if M.poll_accum >= POLL_MS then
        M.poll_accum = 0
        local p  = state_path()
        local mt = file_mtime(p)
        if mt > 0 and mt ~= M.last_mtime then
            local txt = read_file(p)
            local w   = parse_weather(txt)
            if w then
                M.data          = w
                M.last_mtime    = mt
                M.error         = nil
                M.last_update_t = os.time()
                M.need_redraw   = true

                -- 用户手动打开触发的刷新：数据到达后弹 toast
                if M.pending_notify then
                    M.pending_notify = false
                    local where = w.city or "?"
                    local t_str = (M.units == "f")
                        and string.format("%.0f°F", w.temp * 9 / 5 + 32)
                        or  string.format("%.0f°C", w.temp)
                    M.ctx.show_bubble(
                        string.format("%s  %s  %s",
                                      where, t_str, w.desc or ""),
                        { style = "success", duration = 2.5 })
                end
            else
                M.error       = "解析失败"
                M.need_redraw = true

                if M.pending_notify then
                    M.pending_notify = false
                    M.ctx.show_bubble("天气获取失败",
                        { style = "error", duration = 3 })
                end
            end
        end
    end

    -- 定期后台刷新（不弹 toast）
    M:refresh(false, false)

    if M.need_redraw or M.redraw_accum >= REDRAW_MS then
        M.draw()
        M.need_redraw  = false
        M.redraw_accum = 0
    end
end

-- ─── 绘制 ────────────────────────────────────────────────
local function fmt_ago(t)
    if not t or t < 0 then return "等待数据" end
    local s = os.time() - t
    if s < 60 then return "刚刚更新" end
    local m = math.floor(s / 60)
    if m < 60 then return string.format("%d 分钟前更新", m) end
    return string.format("%d 小时前更新", math.floor(m / 60))
end

local function fmt_location(w)
    if not w or not w.city then return "未知位置" end
    if w.region and w.region ~= "" and w.region ~= w.city then
        return w.city .. " · " .. w.region
    end
    return w.city
end

local function fmt_wind(w)
    if not w or not w.wind_kmph or w.wind_kmph == 0 then return "--" end
    local dir = w.wind_dir or "--"
    return string.format("%s %d", dir, math.floor(w.wind_kmph))
end

function M.draw()
    if not M.surf then return end
    local ui, s, T = M.ui, M.surf, M.ui.theme
    local lh, PAD = M.LH, M.PAD

    s:clear(T.bg)
    ui:begin()

    -- ── 顶栏 ──
    local hh = lh + 20
    s:rect(0, 0, M.W, hh, T.surface)
    local hy = math.floor((hh - lh) / 2)
    s:text(PAD, hy, "天气", T.primary)

    local loc_str = M.data and fmt_location(M.data) or "定位中…"
    local lw = select(1, M.ctx.get_text_size(loc_str))
    s:text(M.W - PAD - lw, hy, loc_str, T.on_var)
    s:rect(0, hh - 1, M.W, 1, T.outline)

    local y = hh + 18

    if M.data then
        local w = M.data

        -- 大号温度（左）+ 图标（右）
        local temp = (M.units == "f")
            and string.format("%d°F", math.floor(w.temp * 9 / 5 + 32))
            or  string.format("%d°C", math.floor(w.temp))
        s:text(PAD, y, temp, T.on_surface)

        local icon = icon_for(w.desc)
        local iw   = select(1, M.ctx.get_text_size(icon))
        s:text(M.W - PAD - iw - 2, y - 2, icon, T.primary_hi)

        -- 描述
        y = y + lh + 6
        s:text(PAD, y, w.desc or "--", T.on_var)

        y = y + lh + 18
        s:rect(PAD, y - 10, M.W - PAD * 2, 1, T.outline)

        -- 三列统计
        local col_w = math.floor((M.W - PAD * 2) / 3)
        local cells = {
            { "体感", string.format("%d°", math.floor(w.feels)) },
            { "湿度", string.format("%d%%", math.floor(w.humidity)) },
            { "风速", fmt_wind(w) },
        }
        for i, c in ipairs(cells) do
            local cx = PAD + (i - 1) * col_w
            s:text(cx, y, c[1], T.outline)
            s:text(cx, y + lh + 4, c[2], T.on_surface)
        end
    else
        -- 加载中 / 失败占位
        s:text(PAD, y, M.error or "获取中…", T.outline)
        y = y + lh + 4
        local hint = M.manual_city
            and ("手动城市: " .. M.manual_city)
            or  "自动定位 + 首次请求约 1–2 秒"
        s:text(PAD, y, hint, T.outline)
    end

    -- ── 底栏 ──
    local by = M.H - lh - 12
    s:rect(PAD, by - 8, M.W - PAD * 2, 1, T.outline)

    local status = M.data and fmt_ago(M.last_update_t)
                or M.error or "等待数据"
    s:text(PAD, by, status, T.outline)

    local src = "wttr.in"
    local sw  = select(1, M.ctx.get_text_size(src))
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