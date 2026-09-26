local M = {}
local UI = require("core.ui")
local Surface = require("core.surface")

function M.init(ctx)
    M.ctx = ctx
    M.ui = UI.new(ctx, {
        primary   = 0xb69eff,   -- from your reference: soft lavender
        on_primary= 0x2e1065,
        secondary_ctr = 0x4a4458,
        green     = 0xd6f26a,   -- lime accent
    })
    M.val = 0.42
    M.on  = true
    M.t   = 0
    M.w, M.h = 480, 380

    M.surf = Surface.new(ctx, M.w, M.h)
    M.ui:attach(M.surf)

    M.canvas = ctx.create_canvas(M.w, M.h, { x = 200, y = 160, bg = M.ui.theme.bg })
    M.canvas:show()

    ctx.register_action("toggle_ui_demo", function()
        if M.canvas.visible then M.canvas:hide() else M.canvas:show() end
    end)
    ctx.on("xevent", function(t, ev) M.ui:on_event(t, ev) end)
    ctx.on("tick", function(dt) M:tick(dt) end)
end

function M:tick(dt)
    if not M.canvas.visible then return end
    M.t = M.t + dt
    local ui, s, T = M.ui, M.surf, M.ui.theme
    s:clear(T.bg)
    ui:begin()

    -- Top bar
    ui:label(24, 20, "UI 组件库", T.on_surface)
    ui:label(M.w - 130, 22, "M3 · 深色", T.on_var)

    -- Hero card
    ui:card(24, 60, M.w - 48, 110, { radius = 20 })
    ui:label(44, 80, "Material You", T.primary)
    ui:label(44, 106, "动态色彩 · 圆角 · 无锯齿渲染", T.on_var, T.surface)

    -- Buttons row
    local by = 194
    ui:button(24, by, 120, 40, "主操作", { filled = true })
    ui:button(156, by, 120, 40, "次级", { tonal = true })
    ui:button(288, by, 120, 40, "文字", {})

    -- Slider
    ui:label(24, 252, string.format("进度  %.0f%%", M.val * 100), T.on_var)
    local nv, ch = ui:slider("demo1", 24, 288, M.w - 48, M.val)
    if ch then M.val = nv end

    -- Toggle row
    ui:label(24, 314, "启用发光", T.on_var)
    local nv2, ch2 = ui:toggle("demo2", 380, 310, 76, 40, M.on)
    if ch2 then M.on = nv2 end

    -- Pulsing accent bar
    local pulse = 0.5 + 0.5 * math.sin(M.t / 400)
    ui:label(24, 348, "动画", T.on_var)
    s:rrect(120, 350, M.w - 144, 6, 3, T.surface_hi)
    s:rrect(120, 350, math.floor((M.w - 144) * pulse), 6, 3, T.green)

    ui:end_frame()

    -- Flush the surface into the canvas window
    local dpy = M.ctx.dpy
    local X11 = M.ctx.X11
    s:flush(M.canvas.win, M.canvas.wgc, 0, 0)
end

function M.shutdown()
    if M.surf then M.surf:destroy() end
    if M.canvas then M.canvas:destroy() end
end

return M