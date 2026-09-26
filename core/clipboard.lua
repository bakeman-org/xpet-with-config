local M = {}

local function has_cmd(cmd)
    local f = io.popen("command -v " .. cmd .. " 2>/dev/null")
    if not f then return false end
    local r = f:read("*l")
    f:close()
    return r ~= nil and r ~= ""
end

local BACKEND = nil

local function detect_backend()
    if BACKEND then return BACKEND end
    if os.getenv("WAYLAND_DISPLAY") and has_cmd("wl-copy") and has_cmd("wl-paste") then
        BACKEND = "wayland"
    elseif has_cmd("xclip") then
        BACKEND = "xclip"
    elseif has_cmd("xsel") then
        BACKEND = "xsel"
    else
        BACKEND = "none"
    end
    return BACKEND
end

function M.copy(text)
    if not text or text == "" then return false end
    local b = detect_backend()
    if b == "none" then return false end

    local tmp = os.tmpname()
    local f = io.open(tmp, "w")
    if not f then return false end
    f:write(text)
    f:close()

    local cmd
    if b == "wayland" then
        cmd = string.format("wl-copy < '%s' 2>/dev/null", tmp)
    elseif b == "xclip" then
        cmd = string.format("xclip -selection clipboard -i < '%s' 2>/dev/null", tmp)
    else
        cmd = string.format("xsel -b -i < '%s' 2>/dev/null", tmp)
    end
    os.execute(cmd)
    os.remove(tmp)
    return true
end

function M.paste()
    local b = detect_backend()
    if b == "none" then return nil end

    local cmd
    if b == "wayland" then
        cmd = "wl-paste --no-newline 2>/dev/null"
    elseif b == "xclip" then
        cmd = "xclip -selection clipboard -o 2>/dev/null"
    else
        cmd = "xsel -b -o 2>/dev/null"
    end
    local f = io.popen(cmd)
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then return nil end
    return content
end

function M.backend()
    return detect_backend()
end

return M