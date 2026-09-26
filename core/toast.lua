local M = {}

local Toast = {}
Toast.__index = Toast

local PAD_X = 20
local PAD_Y = 14
local RADIUS = 14
local ACCENT_W = 4
local DEFAULT_DURATION = 3.0

-- 硬限制：单条 toast 最多显示多少字符
local MAX_CHARS = 512
-- 单行最大宽度 = 屏宽 × 该比例
local MAX_LINE_W_RATIO = 0.72
-- 最大行数，超出直接截断
local MAX_LINES = 8

local STYLES = {
    info    = { bg = 0x1e1e2e, fg = 0xe6e1e5, accent = 0x89b4fa },
    success = { bg = 0x1e1e2e, fg = 0xe6e1e5, accent = 0xa6e3a1 },
    warning = { bg = 0x1e1e2e, fg = 0xe6e1e5, accent = 0xf9e2af },
    error   = { bg = 0x1e1e2e, fg = 0xe6e1e5, accent = 0xf38ba8 },
    plain   = { bg = 0xffffff, fg = 0x000000, accent = nil },
}

local function resolve_style(s)
    if type(s) == "table" then return s end
    return STYLES[s or "info"] or STYLES.info
end

local function utf8_step(s, i)
    local b = s:byte(i)
    if not b then return 1 end
    if b < 0x80 then return 1 end
    if b < 0xE0 then return 2 end
    if b < 0xF0 then return 3 end
    return 4
end

local function utf8_truncate(s, max_chars)
    local i = 1
    local L = #s
    local n = 0
    while i <= L do
        if n >= max_chars then
            -- 需要截断
            local cut = i
            while cut > 1 do
                local b = s:byte(cut)
                if b and b >= 0x80 and b < 0xC0 then cut = cut - 1
                else break end
            end
            return s:sub(1, cut - 1) .. "…"
        end
        i = i + utf8_step(s, i)
        n = n + 1
    end
    return s
end

local function wrap_text(ctx, text, max_w, max_lines)
    -- 先测整段宽度；不够则逐字符换行
    if select(1, ctx.get_text_size(text)) <= max_w then
        return text, 1
    end
    local lines = {}
    local buf = {}
    local buf_w = 0
    local i = 1
    local L = #text
    local line_count = 0
    while i <= L do
        local step = utf8_step(text, i)
        local ch = text:sub(i, i + step - 1)
        if ch == "\n" then
            lines[#lines + 1] = table.concat(buf)
            buf = {}
            buf_w = 0
            line_count = line_count + 1
            if max_lines and line_count >= max_lines then
                return table.concat(lines, "\n"), line_count
            end
        else
            local cw = select(1, ctx.get_text_size(ch))
            if buf_w + cw > max_w and #buf > 0 then
                lines[#lines + 1] = table.concat(buf)
                buf = { ch }
                buf_w = cw
                line_count = line_count + 1
                if max_lines and line_count >= max_lines then
                    -- 最后一行加省略号
                    if i < L then
                        buf[#buf + 1] = "…"
                    end
                    lines[#lines + 1] = table.concat(buf)
                    return table.concat(lines, "\n"), line_count
                end
            else
                buf[#buf + 1] = ch
                buf_w = buf_w + cw
            end
        end
        i = i + step
    end
    if #buf > 0 then
        lines[#lines + 1] = table.concat(buf)
        line_count = line_count + 1
    end
    return table.concat(lines, "\n"), line_count
end

function M.new(ctx)
    local self = setmetatable({}, Toast)
    self.ctx = ctx
    self.canvas = nil
    self.style = nil
    self.text = nil
    self.deadline = 0
    self.anchor = nil
    self.visible = false
    self.x, self.y = 0, 0
    self.w, self.h = 0, 0
    return self
end

function Toast:_ensure_canvas(w, h, style)
    if self.canvas and self.canvas.w == w and self.canvas.h == h
       and self._style_ref == style then
        return self.canvas
    end
    if self.canvas then
        self.canvas:destroy()
        self.canvas = nil
    end
    self.canvas = self.ctx.create_canvas(w, h, {
        bg = style.bg,
        border = style.bg,
        border_width = 0,
    })
    self._style_ref = style
    return self.canvas
end

-- 处理文本：截断 + 换行。返回 (prepared_text, w, h)
function Toast:_prepare(text, style)
    local max_w = math.floor(self.ctx.scr_w * MAX_LINE_W_RATIO)

    -- 1. 字符数硬截断
    text = utf8_truncate(text, MAX_CHARS)

    -- 2. 自动换行
    text, _ = wrap_text(self.ctx, text, max_w, MAX_LINES)

    -- 3. 尺寸
    local tw, th = self.ctx.get_text_size(text)
    local pad_l = PAD_X + (style.accent and ACCENT_W or 0)
    return text, tw + pad_l + PAD_X, th + PAD_Y * 2
end

function Toast:show(text, opts)
    if not text or text == "" then return end
    opts = opts or {}
    local style = resolve_style(opts.style)

    local prepared, bw, bh = self:_prepare(text, style)
    local canvas = self:_ensure_canvas(bw, bh, style)

    self.text     = prepared
    self.style    = style
    self.w, self.h = bw, bh
    self.deadline = opts.duration or DEFAULT_DURATION
    self.anchor   = opts.anchor

    local tx, ty
    if self.anchor then
        tx, ty = self.anchor({ w = bw, h = bh })
    else
        tx = math.floor((self.ctx.scr_w - bw) / 2)
        ty = math.floor(self.ctx.scr_h * 0.82)
    end
    canvas:move(math.floor(tx), math.floor(ty))
    self.x, self.y = tx, ty

    canvas:show()
    self:_redraw()
    self.visible = true
end

function Toast:_redraw()
    if not self.canvas or not self.text then return end
    local c, ctx = self.canvas, self.ctx
    local style = self.style

    c:clear()

    if style.accent then
        c:rrect(0, 0, ACCENT_W, c.h, ACCENT_W / 2, style.accent)
    end

    local text_x = PAD_X + (style.accent and ACCENT_W or 0)
    ctx.FT.xft_draw(ctx.ft_ctx, ctx.dpy, c.pixmap, c.pgc,
                    text_x, PAD_Y - 4, self.text, style.fg, style.bg)
    c:flush()
end

function Toast:tick(dt_ms)
    if not self.visible then return end

    if self.anchor then
        local tx, ty = self.anchor({ w = self.w, h = self.h })
        if math.floor(tx) ~= math.floor(self.x)
           or math.floor(ty) ~= math.floor(self.y) then
            self.canvas:move(math.floor(tx), math.floor(ty))
            self.x, self.y = tx, ty
        end
    end

    self.deadline = self.deadline - dt_ms / 1000
    if self.deadline <= 0 then
        self:hide()
    end
end

function Toast:hide()
    if self.canvas then self.canvas:hide() end
    self.visible = false
    self.text = nil
    self.deadline = 0
    self.anchor = nil
end

function Toast:clear()
    if self.canvas then
        self.canvas:destroy()
        self.canvas = nil
    end
    self._style_ref = nil
    self.visible = false
    self.text = nil
    self.deadline = 0
    self.anchor = nil
end

return M