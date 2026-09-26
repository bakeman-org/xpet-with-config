local M = {}

function M.init(ctx)
    ctx.register_action("show_keybinds_help", function()
        local lines = { "Help / Keybinds:" }
        for _, kb in ipairs(ctx.config.keybinds or {}) do
            lines[#lines + 1] = string.format("%s+%s : %s", kb.mod, kb.key, kb.action)
        end
        ctx.show_bubble(table.concat(lines, "\n"))
    end)
end

return M