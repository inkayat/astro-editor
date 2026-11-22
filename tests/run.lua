-- Headless tests: nvim -l tests/run.lua
-- Each case starts the real Neovim binary the way AstroApp launches it
-- (NVIM_APPNAME=astro-editor, runtime prepended to 'runtimepath') under a
-- throwaway XDG home, then checks the state tests/probe.lua records.
local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local tmp = vim.fn.tempname()
local failures = 0

local function write(path, lines)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
  vim.fn.writefile(lines, path)
end

-- Synthetic XDG home. config/nvim stands in for the person's own (e.g.
-- LazyVim) config, which AstroEditor must not load; config/astro-editor is
-- the AstroEditor profile's own config, with one ordinary start package.
local xdg = tmp .. '/xdg'
write(xdg .. '/config/nvim/init.lua', { 'vim.g.test_person_nvim_config = true' })
write(xdg .. '/config/astro-editor/init.lua', { 'vim.g.test_user_init = true' })
write(xdg .. '/config/astro-editor/pack/user/start/demo/plugin/demo.lua', { 'vim.g.test_user_plugin = true' })

-- Workspace fixtures; names carry characters Ex would otherwise expand.
local root = tmp .. '/work space %#$x'
local notes = root .. '/notes %1.txt'
local work = root .. '/main #2.txt'
local base = tmp .. '/base/main #2.txt'
local work_lines, base_lines = {}, {}
for i = 1, 200 do
  work_lines[i] = 'line ' .. i
  base_lines[i] = (i >= 120 and i <= 122) and ('old ' .. i) or ('line ' .. i)
end
write(notes, vim.split(('n\n'):rep(50), '\n', { trimempty = true }))
write(work, work_lines)
write(base, base_lines)

local function launch(manifest)
  local out = tmp .. '/probe.json'
  vim.fn.delete(out)
  local env = {
    NVIM_APPNAME = 'astro-editor',
    XDG_CONFIG_HOME = xdg .. '/config',
    XDG_DATA_HOME = xdg .. '/data',
    XDG_STATE_HOME = xdg .. '/state',
    XDG_CACHE_HOME = xdg .. '/cache',
    PROBE_OUT = out,
  }
  if manifest then
    env.ASTRO_EDITOR_MANIFEST = tmp .. '/manifest.json'
    vim.fn.writefile({ vim.json.encode(manifest) }, env.ASTRO_EDITOR_MANIFEST)
  end
  local res = vim.system({
    vim.v.progpath, '--headless',
    '--cmd', 'set rtp^=' .. repo:gsub('[ ,\\]', '\\%0'),
    '-c', 'luafile ' .. vim.fn.fnameescape(repo .. '/tests/probe.lua'),
  }, { env = env, cwd = tmp, text = true }):wait(20000)
  assert(vim.fn.filereadable(out) == 1, 'no probe output; stderr: ' .. (res.stderr or ''))
  return vim.json.decode(table.concat(vim.fn.readfile(out), '\n'))
end

local function case(name, manifest, check)
  local ok, err = pcall(function()
    local s = launch(manifest)
    assert(s.user_init and s.user_plugin, 'AstroEditor config or user plugin not loaded')
    assert(not s.person_nvim_config, "the person's own nvim config was loaded")
    assert(s.manifest_env == vim.NIL, 'ASTRO_EDITOR_MANIFEST left in the environment')
    check(s)
  end)
  io.write((ok and 'ok   ' or 'FAIL ') .. name .. (ok and '' or ('\n     ' .. tostring(err))) .. '\n')
  if not ok then
    failures = failures + 1
  end
end

local function eq(want, got, what)
  assert(want == got, ('%s: want %s, got %s'):format(what, vim.inspect(want), vim.inspect(got)))
end

case('no manifest: plain Neovim', nil, function(s)
  eq('', s.buf, 'buffer')
  eq('', s.errmsg, 'errmsg')
end)

case('files: opens the folder', { version = 1, kind = 'files', root = root }, function(s)
  eq(vim.uv.fs_realpath(root), vim.uv.fs_realpath(s.cwd), 'cwd')
  eq('netrw', s.filetype, 'filetype')
end)

case('file: opens at the requested line', { version = 1, kind = 'file', path = notes, line = 37 }, function(s)
  eq(notes, s.buf, 'buffer')
  eq(37, s.line, 'line')
end)

case('file: line past the end lands on the last line', { version = 1, kind = 'file', path = notes, line = 999 }, function(s)
  eq(50, s.line, 'line')
end)

case('diff: whole-file diff with native motions', { version = 1, kind = 'diff', path = work, base = base }, function(s)
  eq(2, #s.windows, 'windows')
  eq(base, s.windows[1].name, 'left window')
  eq(work, s.windows[2].name, 'right window')
  assert(s.windows[1].diff and s.windows[2].diff, 'both windows in diff mode')
  eq(false, s.windows[1].modifiable, 'base modifiable')
  eq(true, s.windows[2].modifiable, 'work modifiable')
  eq(work, s.buf, 'current buffer')
  eq(120, s.hunk_line, ']c lands on the hunk')
  eq(200, s.end_line, 'G reaches the end of the file')
  eq(200, s.line_count, 'whole file loaded')
end)

for _, bad in ipairs({
  { why = 'relative path', m = { version = 1, kind = 'file', path = 'notes.txt' }, msg = 'path must be an absolute path' },
  { why = 'missing file', m = { version = 1, kind = 'diff', path = work, base = tmp .. '/nope' }, msg = 'cannot open base' },
  { why = 'unknown kind', m = { version = 1, kind = 'pr' }, msg = 'unknown kind' },
  { why = 'wrong version', m = { version = 2, kind = 'files', root = root }, msg = 'unsupported manifest version' },
  { why = 'bad line', m = { version = 1, kind = 'file', path = notes, line = 0 }, msg = 'line must be a positive integer' },
}) do
  case('refuses ' .. bad.why, bad.m, function(s)
    assert(s.errmsg:find('astro-editor: ' .. bad.msg, 1, true), 'errmsg: ' .. s.errmsg)
    eq('', s.buf, 'buffer')
    eq(1, #s.windows, 'windows')
  end)
end

vim.fn.delete(tmp, 'rf')
if failures > 0 then
  io.write(failures .. ' failed\n')
  os.exit(1)
end
io.write('all passed\n')
