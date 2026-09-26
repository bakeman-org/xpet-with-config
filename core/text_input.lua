local M = {}
local Clipboard = require("core.clipboard")

local TI = {}
TI.__index = TI

-- ─── UTF-8 helpers ────────────────────────────────────────

local function utf8_step(s, i)
    local b = s:byte(i)
    if not b then return 1 end
    if b < 0x80 then return 1 end
    if b < 0xE0 then return 2 end
    if b < 0xF0 then return 3 end
    return 4
end

local function utf8_prev(s, i)
    if i <= 1 then return 1 end
    local j = i - 1
    while j > 1 do
        local b = s:byte(j)
        if b and b >= 0x80 and b < 0xC0 then j = j - 1
        else break end
    end
    return j
end

local function utf8_next(s, i)
    local n = #s
    if i > n then return n + 1 end
    return math.min(i + utf8_step(s, i), n + 1)
end

local function splice(s, a, b, insert)
    return s:sub(1, a - 1) .. (insert or "") .. s:sub(b)
end

local function prev_word(s, i)
    if i <= 1 then return 1 end
    local j = i - 1
    while j >= 1 and s:byte(j) == 0x20 do j = j - 1 end
    while j >= 1 and s:byte(j) ~= 0x20 do
        j = utf8_prev(s, j + 1) - 1
    end
    return j + 1
end

local function next_word(s, i)
    local n = #s
    if i > n then return n + 1 end
    local j = i
    while j <= n and s:byte(j) ~= 0x20 do j = utf8_next(s, j) end
    while j <= n and s:byte(j) == 0x20 do j = j + 1 end
    return j
end

-- ─── 构造 ─────────────────────────────────────────────────

function M.new(ctx, opts)
    opts = opts or {}
    local self = setmetatable({}, TI)
    self.ctx       = ctx
    self.value     = opts.value or ""
    self.cursor    = #self.value + 1
    self.anchor    = nil
    self.scroll_x  = 0
    self.focused   = false
    self.blink_on  = true
    self.blink_t   = 0
    self.blink_ms  = 530

    self.x, self.y, self.w, self.h = 0, 0, 0, 0
    self.pad_l     = opts.pad_l or 12
    self.pad_r     = opts.pad_r or 12
    self.placeholder = opts.placeholder
    self.font_lh   = ctx.get_primary_line_height()

    -- 长度上限（字节）。默认 8KB，够 2000+ 个中文字符
    self.max_bytes = opts.max_bytes or 8192

    self.on_change = opts.on_change
    self.on_submit = opts.on_submit
    self.on_cancel = opts.on_cancel
    self.on_limit  = opts.on_limit   -- 达到上限时通知

    self.dragging    = false
    self.drag_origin = nil

    self._click_count = 0
    self._last_click_t = 0
    self._last_click_x = 0
    self._last_click_y = 0

    -- 缓存
    self._char_w   = {}      -- char_w[byte_pos] = 该字符像素宽
    self._prefix_w = {[1]=0} -- prefix_w[byte_pos] = 前 (byte_pos-1) 字节总宽
    self._positions = {1}    -- 所有合法字节边界
    self._dirty = true

    return self
end

function TI:_invalidate()
    self._dirty = true
end

function TI:_rebuild_cache()
    local s = self.value
    local n = #s
    local char_w = {}
    local prefix_w = { [1] = 0 }
    local positions = { 1 }
    local acc = 0
    local i = 1
    while i <= n do
        local step = utf8_step(s, i)
        local ni = i + step
        if ni > n + 1 then ni = n + 1 end
        local ch = s:sub(i, ni - 1)
        local w = select(1, self.ctx.get_text_size(ch))
        char_w[i] = w
        acc = acc + w
        prefix_w[ni] = acc
        positions[#positions + 1] = ni
        i = ni
    end
    self._char_w   = char_w
    self._prefix_w = prefix_w
    self._positions = positions
    self._dirty = false
end

function TI:set_rect(x, y, w, h)
    self.x, self.y, self.w, self.h = x, y, w, h
    self.text_x = x + self.pad_l
    self.text_w = w - self.pad_l - self.pad_r
end

function TI:set_value(s)
    s = s or ""
    if self.max_bytes and #s > self.max_bytes then
        local cut = self.max_bytes
        while cut > 0 do
            local b = s:byte(cut + 1)
            if not b or b < 0x80 or b >= 0xC0 then break end
            cut = cut - 1
        end
        s = s:sub(1, cut)
    end
    self.value = s
    if self.cursor > #self.value + 1 then
        self.cursor = #self.value + 1
    end
    if self.anchor and self.anchor > #self.value + 1 then
        self.anchor = #self.value + 1
    end
    self:_invalidate()
    if self.on_change then self.on_change(self.value) end
end

function TI:focus()
    self.focused = true
    self.blink_on = true
    self.blink_t = 0
end

function TI:blur()
    self.focused = false
    self.anchor = nil
    self.dragging = false
end

function TI:has_selection()
    return self.anchor and self.anchor ~= self.cursor
end

function TI:sel_range()
    if not self:has_selection() then return nil, nil end
    local a, b = self.anchor, self.cursor
    if a > b then a, b = b, a end
    return a, b
end

function TI:contains(mx, my)
    return mx >= self.x and mx < self.x + self.w
       and my >= self.y and my < self.y + self.h
end

-- ─── 位置换算（O(1) / O(log n)）───────────────────────────

function TI:_x_of(i)
    if self._dirty then self:_rebuild_cache() end
    local w = self._prefix_w[i] or 0
    return self.text_x - self.scroll_x + w
end

function TI:_pos_of(x)
    if self._dirty then self:_rebuild_cache() end
    local n = #self.value
    if n == 0 then return 1 end
    local target = x - self.text_x + self.scroll_x
    if target <= 0 then return 1 end

    local positions = self._positions
    local prefix_w  = self._prefix_w
    local lo, hi = 1, #positions
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        local p = positions[mid]
        if (prefix_w[p] or 0) < target then lo = mid + 1
        else hi = mid end
    end
    if lo > 1 then
        local a = positions[lo - 1]
        local b = positions[lo]
        local wa = prefix_w[a] or 0
        local wb = prefix_w[b] or 0
        if target - wa < wb - target then return a end
    end
    return positions[lo]
end

function TI:_ensure_cursor_visible()
    local cx = self:_x_of(self.cursor)
    local left  = self.text_x
    local right = self.text_x + self.text_w
    if cx < left then
        self.scroll_x = self.scroll_x - (left - cx)
    elseif cx > right - 2 then
        self.scroll_x = self.scroll_x + (cx - (right - 2))
    end
    if self.scroll_x < 0 then self.scroll_x = 0 end
end

-- ─── 编辑 ────────────────────────────────────────────────

function TI:_delete_selection()
    local a, b = self:sel_range()
    if not a then return false end
    self.value = splice(self.value, a, b)
    self.cursor = a
    self.anchor = nil
    self:_invalidate()
    if self.on_change then self.on_change(self.value) end
    return true
end

function TI:_insert(text)
    if not text or text == "" then return end
    if self:has_selection() then self:_delete_selection() end

    -- 长度上限（字节）
    if self.max_bytes then
        local budget = self.max_bytes - #self.value
        if budget <= 0 then
            if self.on_limit then self.on_limit() end
            return
        end
        if #text > budget then
            local cut = budget
            while cut > 0 do
                local b = text:byte(cut + 1)
                if not b or b < 0x80 or b >= 0xC0 then break end
                cut = cut - 1
            end
            text = text:sub(1, cut)
            if self.on_limit then self.on_limit() end
        end
    end

    local i = self.cursor
    self.value = splice(self.value, i, i, text)
    self.cursor = i + #text
    self:_invalidate()
    if self.on_change then self.on_change(self.value) end
end

function TI:select_all()
    if #self.value == 0 then return end
    self.anchor = 1
    self.cursor = #self.value + 1
end

function TI:clear()
    self.value = ""
    self.cursor = 1
    self.anchor = nil
    self.scroll_x = 0
    self:_invalidate()
    if self.on_change then self.on_change(self.value) end
end

function TI:copy()
    local a, b = self:sel_range()
    if not a then return false end
    Clipboard.copy(self.value:sub(a, b - 1))
    return true
end

function TI:cut()
    local a, b = self:sel_range()
    if not a then return false end
    Clipboard.copy(self.value:sub(a, b - 1))
    self:_delete_selection()
    return true
end

function TI:paste()
    local content = Clipboard.paste()
    if not content or content == "" then return false end
    content = content:gsub("[\r\n]+", " ")
    self:_insert(content)
    return true
end

-- ─── 键盘 ────────────────────────────────────────────────

local XK_Left      = 0xff51
local XK_Right     = 0xff53
local XK_Home      = 0xff50
local XK_End       = 0xff57
local XK_BackSpace = 0xff08
local XK_Delete    = 0xffff
local XK_Return    = 0xff0d
local XK_KP_Enter  = 0xff8d
local XK_Escape    = 0xff1b
local XK_a         = 0x61
local XK_c         = 0x63
local XK_u         = 0x75
local XK_v         = 0x76
local XK_w         = 0x77
local XK_x         = 0x78
local XK_y         = 0x79
local XK_z         = 0x7a

function TI:on_key(sym, ctrl, shift, text)
    if ctrl then
        if sym == XK_a then self:select_all(); return true
        elseif sym == XK_c then self:copy(); return true
        elseif sym == XK_x then self:cut();  return true
        elseif sym == XK_v then self:paste(); return true
        elseif sym == XK_u then self:clear(); return true
        elseif sym == XK_w then
            if self:has_selection() then
                self:_delete_selection()
            else
                local a = prev_word(self.value, self.cursor)
                if a < self.cursor then
                    self.value = splice(self.value, a, self.cursor)
                    self.cursor = a
                    self:_invalidate()
                    if self.on_change then self.on_change(self.value) end
                end
            end
            return true
        elseif sym == XK_y then return true
        elseif sym == XK_z then return true
        end
    end

    if sym == XK_Left then
        local ni = ctrl and prev_word(self.value, self.cursor)
                          or utf8_prev(self.value, self.cursor)
        if shift then
            if not self.anchor then self.anchor = self.cursor end
        else
            self.anchor = nil
        end
        self.cursor = ni
        return true
    elseif sym == XK_Right then
        local ni = ctrl and next_word(self.value, self.cursor)
                          or utf8_next(self.value, self.cursor)
        if shift then
            if not self.anchor then self.anchor = self.cursor end
        else
            self.anchor = nil
        end
        self.cursor = ni
        return true
    elseif sym == XK_Home then
        if shift then
            if not self.anchor then self.anchor = self.cursor end
        else
            self.anchor = nil
        end
        self.cursor = 1
        return true
    elseif sym == XK_End then
        if shift then
            if not self.anchor then self.anchor = self.cursor end
        else
            self.anchor = nil
        end
        self.cursor = #self.value + 1
        return true
    elseif sym == XK_BackSpace then
        if self:has_selection() then
            self:_delete_selection()
        else
            local a = ctrl and prev_word(self.value, self.cursor)
                            or utf8_prev(self.value, self.cursor)
            if a < self.cursor then
                self.value = splice(self.value, a, self.cursor)
                self.cursor = a
                self:_invalidate()
                if self.on_change then self.on_change(self.value) end
            end
        end
        return true
    elseif sym == XK_Delete then
        if self:has_selection() then
            self:_delete_selection()
        else
            local b = ctrl and next_word(self.value, self.cursor)
                            or utf8_next(self.value, self.cursor)
            if b > self.cursor then
                self.value = splice(self.value, self.cursor, b)
                self:_invalidate()
                if self.on_change then self.on_change(self.value) end
            end
        end
        return true
    elseif sym == XK_Return or sym == XK_KP_Enter then
        if self.on_submit then self.on_submit(self.value) end
        return true
    elseif sym == XK_Escape then
        if self.on_cancel then self.on_cancel() end
        return true
    end

    if text and #text > 0 then
        local first = text:byte(1)
        if first and first >= 0x20 then
            self:_insert(text)
            return true
        end
    end

    return false
end

-- ─── 鼠标 ────────────────────────────────────────────────

function TI:_update_click_count(mx, my)
    local now = os.clock() * 1000
    if self._click_count > 0
       and now - self._last_click_t < 400
       and math.abs(mx - self._last_click_x) < 4
       and math.abs(my - self._last_click_y) < 4 then
        self._click_count = self._click_count + 1
        if self._click_count > 3 then self._click_count = 1 end
    else
        self._click_count = 1
    end
    self._last_click_t = now
    self._last_click_x = mx
    self._last_click_y = my
end

function TI:on_mouse_press(mx, my, shift_held)
    if not self:contains(mx, my) then return false end
    self:_update_click_count(mx, my)

    local pos = self:_pos_of(mx)

    if self._click_count == 2 then
        local a = prev_word(self.value, pos)
        local b = next_word(self.value, pos)
        if a == b then a = pos; b = pos end
        self.anchor = a
        self.cursor = b
    elseif self._click_count >= 3 then
        self:select_all()
    else
        if shift_held then
            if not self.anchor then self.anchor = self.cursor end
        else
            self.anchor = nil
        end
        self.cursor = pos
    end

    self.dragging = true
    self.drag_origin = pos
    self.blink_on = true
    self.blink_t = 0
    return true
end

function TI:on_mouse_move(mx, my)
    if not self.dragging then return false end
    local pos = self:_pos_of(mx)
    if not self.anchor then self.anchor = self.drag_origin end
    self.cursor = pos
    return true
end

function TI:on_mouse_release()
    if self.dragging then
        self.dragging = false
        return true
    end
    return false
end

-- ─── 绘制 ────────────────────────────────────────────────

function TI:draw(s, theme)
    local lh = self.font_lh
    if self._dirty then self:_rebuild_cache() end

    -- 背景
    local bg = self.focused and (theme.bg_focus or theme.surface_hi)
                         or (theme.bg or theme.surface)
    local r = theme.radius or math.floor(self.h / 2)
    s:rrect(self.x, self.y, self.w, self.h, r, bg)

    if self.focused then
        local outline = theme.outline_focus or theme.primary
        local ix = self.x + r
        local iw = self.w - 2 * r
        if iw > 0 then
            s:rect(ix, self.y, iw, 1, outline)
            s:rect(ix, self.y + self.h - 1, iw, 1, outline)
        end
    end

    local text_y = self.y + math.floor((self.h - lh) / 2)

    -- 选择背景
    local a, b = self:sel_range()
    if a then
        local x1 = self:_x_of(a)
        local x2 = self:_x_of(b)
        local cx1 = math.max(x1, self.text_x)
        local cx2 = math.min(x2, self.text_x + self.text_w)
        if cx2 > cx1 then
            s:rrect(cx1, text_y - 2, cx2 - cx1, lh + 4,
                    theme.sel_radius or 3,
                    theme.sel_bg or theme.primary)
        end
    end

    -- 文本（只画可视区）
    if #self.value == 0 and self.placeholder then
        s:text(self.text_x, text_y, self.placeholder,
               theme.text_dim or theme.outline)
    else
        local n = #self.value
        local start_i = 1
        local end_i = n + 1
        if n > 0 then
            start_i = self:_pos_of(self.text_x)
            end_i   = self:_pos_of(self.text_x + self.text_w)
            if end_i <= start_i then end_i = start_i + 1 end
        end
        local visible = self.value:sub(start_i, end_i - 1)
        local draw_x = self:_x_of(start_i)
        if draw_x < self.text_x then draw_x = self.text_x end
        if #visible > 0 then
            s:text(draw_x, text_y, visible, theme.text or theme.on_surface)
        end
    end

    -- 光标
    if self.focused and self.blink_on and not a then
        local cx = self:_x_of(self.cursor)
        if cx >= self.text_x - 1 and cx <= self.text_x + self.text_w + 1 then
            s:rect(cx, text_y - 2, 2, lh + 4,
                   theme.cursor or theme.primary)
        end
    end
end

function TI:tick(dt_ms)
    if not self.focused then
        self.blink_on = true
        return
    end
    self.blink_t = self.blink_t + dt_ms
    if self.blink_t >= self.blink_ms then
        self.blink_t = 0
        self.blink_on = not self.blink_on
    end
end

return M