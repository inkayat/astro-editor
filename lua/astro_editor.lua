-- AstroEditor runtime: opens what one launch manifest asks for, using stock
-- Neovim commands only. The manifest's paths are data: they are checked and
-- escaped, never evaluated. This module never runs another program.
local M = {}

local function fail(msg)
  vim.notify('astro-editor: ' .. msg, vim.log.levels.ERROR)
end

-- Returns nil or an error message.
local function check_path(m, key, is_kind)
  local p = m[key]
  if type(p) ~= 'string' or p == '' or vim.fn.isabsolutepath(p) ~= 1 then
    return key .. ' must be an absolute path'
  end
  if not is_kind(p) then
    return 'cannot open ' .. key .. ': ' .. p
  end
end

local function is_dir(p)
  return vim.fn.isdirectory(p) == 1
end

local function is_file(p)
  return vim.fn.filereadable(p) == 1
end

-- Returns nil or an error message. Unknown fields are ignored.
function M.check(m)
  if type(m) ~= 'table' then
    return 'manifest must be a JSON object'
  end
  if m.version ~= 1 then
    return 'unsupported manifest version: ' .. tostring(m.version)
  end
  local err
  if m.kind == 'files' then
    err = check_path(m, 'root', is_dir)
  elseif m.kind == 'file' then
    err = check_path(m, 'path', is_file)
    local line = m.line
    if not err and line ~= nil and (type(line) ~= 'number' or line < 1 or line ~= math.floor(line)) then
      err = 'line must be a positive integer'
    end
  elseif m.kind == 'diff' then
    err = check_path(m, 'path', is_file) or check_path(m, 'base', is_file)
  else
    err = 'unknown kind: ' .. tostring(m.kind)
  end
  return err
end

local function edit(path)
  vim.cmd('edit ' .. vim.fn.fnameescape(path))
end

-- Opens a decoded manifest. Returns true, or false after notifying the error.
function M.open(m)
  local err = M.check(m)
  if err then
    fail(err)
    return false
  end
  if m.kind == 'files' then
    vim.fn.chdir(m.root)
    edit(m.root)
  elseif m.kind == 'file' then
    edit(m.path)
    local last = vim.api.nvim_buf_line_count(0)
    vim.api.nvim_win_set_cursor(0, { math.min(m.line or 1, last), 0 })
  else
    edit(m.path)
    vim.cmd('leftabove vertical diffsplit ' .. vim.fn.fnameescape(m.base))
    vim.bo.readonly = true
    vim.bo.modifiable = false
    vim.cmd('wincmd p')
  end
  return true
end

-- Reads and opens the manifest file at `path`.
function M.start(path)
  local ok, m = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
  end)
  if not ok then
    fail('cannot read manifest ' .. path .. ': ' .. tostring(m))
    return false
  end
  return M.open(m)
end

return M
