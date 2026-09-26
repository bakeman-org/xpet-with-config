local M = {}
local X11C = require('core.x11_const')

local LOCK_BITS = X11C.LOCK_BITS
local LOCK_VARIANTS = { 0, X11C.LOCK_MASK, X11C.MOD2_MASK, LOCK_BITS }

function M.parse_mods(s, bit)
  if type(s) ~= 'string' then
    return nil
  end
  local mask = 0
  for part in s:gmatch('[^+]+') do
    part = part:match('^%s*(.-)%s*$'):lower()
    local m = X11C.MOD_NAMES[part]
    if not m then
      return nil
    end
    mask = bit.bor(mask, m)
  end
  return mask == 0 and nil or mask
end

function M.grab_root_key(X11, dpy, root, bit, code, mask)
  for _, extra in ipairs(LOCK_VARIANTS) do
    X11.XGrabKey(dpy, code, bit.bor(mask, extra), root, 0, 1, 1)
  end
  X11.XFlush(dpy)
end

function M.ungrab_root_key(X11, dpy, root, bit, code, mask)
  for _, extra in ipairs(LOCK_VARIANTS) do
    X11.XUngrabKey(dpy, code, bit.bor(mask, extra), root)
  end
  X11.XFlush(dpy)
end

function M.new(deps)
  local X11, bit, dpy, root, log = deps.X11, deps.bit, deps.dpy, deps.root, deps.log
  local by_code = {}

  local self = {}

  function self.rebuild(config)
    for k in pairs(by_code) do
      by_code[k] = nil
    end
    X11.XUngrabKey(dpy, 0, 0x8000, root)

    for _, kb in ipairs(config.keybinds or {}) do
      local mask = M.parse_mods(kb.mod, bit)
      if not mask then
        log('unknown modifier: %s', tostring(kb.mod))
      else
        local sym = X11.XStringToKeysym(kb.key)
        local code = X11.XKeysymToKeycode(dpy, sym)
        if code == 0 then
          log('unknown key: %s', tostring(kb.key))
        else
          by_code[code] = { mask = mask, action = kb.action }
          M.grab_root_key(X11, dpy, root, bit, code, mask)
        end
      end
    end
    X11.XFlush(dpy)
    X11.XSync(dpy, 0)
  end

  function self.lookup(keycode, state)
    local entry = by_code[keycode]
    if not entry then
      return nil
    end
    local clean = bit.band(state, bit.bnot(LOCK_BITS))
    if clean == entry.mask then
      return entry.action
    end
    return nil
  end

  return self
end

return M
