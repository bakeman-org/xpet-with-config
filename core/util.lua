local M = {}

function M.logger(tag)
  return function(fmt, ...)
    io.stderr:write('[' .. tag .. '] ' .. string.format(fmt, ...) .. '\n')
  end
end

function M.file_exists(p)
  local f = io.open(p, 'rb')
  if f then
    f:close()
    return true
  end
  return false
end

function M.file_mtime(path)
  local p = io.popen(string.format("stat -c %%Y '%s' 2>/dev/null", path))
  if not p then
    return nil
  end
  local out = p:read('*l')
  p:close()
  return tonumber(out)
end

function M.utf8_step(s, i)
  local b = s:byte(i)
  if not b then
    return 1
  end
  if b < 0x80 then
    return 1
  end
  if b < 0xE0 then
    return 2
  end
  if b < 0xF0 then
    return 3
  end
  return 4
end

function M.utf8_prev(s, i)
  if i <= 1 then
    return 1
  end
  local j = i - 1
  while j > 1 do
    local b = s:byte(j)
    if b and b >= 0x80 and b < 0xC0 then
      j = j - 1
    else
      break
    end
  end
  return j
end

function M.utf8_next(s, i)
  local n = #s
  if i > n then
    return n + 1
  end
  return math.min(i + M.utf8_step(s, i), n + 1)
end

function M.utf8_truncate(s, max_chars)
  local i = 1
  local L = #s
  local n = 0
  while i <= L do
    if n >= max_chars then
      local cut = i
      while cut > 1 do
        local b = s:byte(cut)
        if b and b >= 0x80 and b < 0xC0 then
          cut = cut - 1
        else
          break
        end
      end
      return s:sub(1, cut - 1) .. '…'
    end
    i = i + M.utf8_step(s, i)
    n = n + 1
  end
  return s
end

function M.truncate(s, max)
  if #s <= max then
    return s
  end
  local cut = max - 1
  while cut > 0 do
    local b = s:byte(cut + 1)
    if not b or b < 0x80 or b >= 0xC0 then
      break
    end
    cut = cut - 1
  end
  return s:sub(1, cut) .. '…'
end

function M.keybind_hint(ctx, action)
  for _, kb in ipairs(ctx.config.keybinds or {}) do
    if kb.action == action then
      local parts = {}
      for p in kb.mod:gmatch('[^+]+') do
        parts[#parts + 1] = p:sub(1, 1):upper() .. p:sub(2):lower()
      end
      parts[#parts + 1] = kb.key:upper()
      return table.concat(parts, '+')
    end
  end
  return '?'
end

return M
