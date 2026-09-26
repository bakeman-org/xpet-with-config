local M = {}

local Toast = {}
Toast.__index = Toast

local PAD_X = 20
local PAD_Y = 14
local RADIUS = 14
local ACCENT_W = 4
local DEFAULT_DURATION = 3.0

-- Material 3 dark palette + a "plain" white legacy bubble
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

function Toast:_compute_size(text, style)
    local tw, th = self.ctx.get_text_size(text)
    local pad_l = PAD_X + (style.accent and ACCENT_W or 0)
    return tw + pad_l + PAD_X,
           th + PAD_Y * 2
end

function Toast:show(text, opts)
    if not text or text == "" then return end
    opts = opts or {}
    local style = resolve_style(opts.style)

    local bw, bh = self:_compute_size(text, style)
    local canvas = self:_ensure_canvas(bw, bh, style)

    self.text     = text
    self.style    = style
    self.w, self.h = bw, bh
    self.deadline = opts.duration or DEFAULT_DURATION
    self.anchor   = opts.anchor

    -- initial position
    local tx, ty
    if self.anchor then
        tx, ty = self.anchor({ w = bw, h = bh })
    else
        tx = math.floor((self.ctx.scr_w - bw) / 2)
        ty = math.floor(self.ctx.scr_h * 0.82)
    end
    canvas:move(math.floor(tx), math.floor(ty))
    self.x, self.y = tx, ty

    -- ★ FIX: map the window BEFORE painting, otherwise the first
    -- frame is blank and needs a second trigger.
    canvas:show()
    self:_redraw()
    self.visible = true
end

function Toast:_redraw()
    if not self.canvas or not self.text then return end
    local c, ctx = self.canvas, self.ctx
    local style = self.style

    c:clear()  -- fill entire window with style.bg

    -- Left accent bar (rounded for aesthetics)
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