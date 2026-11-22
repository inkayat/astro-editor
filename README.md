# astro-editor

Plain Neovim runtime for AstroEditor.

AstroEditor is stock Neovim with its own profile: no LazyVim, no plugin
manager, no changes to your existing Neovim config. This repository holds the
small Lua runtime that opens what Astro asks for (a folder, a file at a line,
a whole-file diff, or a list of changed files) and then gets out of the way.
Navigation is ordinary Neovim: netrw for folders, `]c` / `[c`, `do` / `dp`,
`gg` / `G` and folds in diffs, `]q` / `[q` through changed files.
`:AstroContext` sends a selection or location, with a note, to a destination
Astro declared for the launch.

The runtime never runs git, a shell or any other program, and opens no
network connection. Diffs use Neovim's built-in diff.

## Launch

```sh
NVIM_APPNAME=astro-editor \
ASTRO_EDITOR_MANIFEST=/path/to/manifest.json \
nvim --cmd 'set rtp^=/path/to/astro-editor'
```

- `NVIM_APPNAME=astro-editor` gives AstroEditor its own config, data and state
  directories (`~/.config/astro-editor`, …), so `~/.config/nvim` is never read.
- `--cmd 'set rtp^=…'` puts this runtime first on `'runtimepath'`. Escape
  spaces, commas and backslashes in the path as `:set` requires.
- `ASTRO_EDITOR_MANIFEST` names one launch manifest. Without it the runtime does
  nothing and Neovim starts as usual. The runtime removes the variable from its
  environment so a nested Neovim does not open the manifest again.

The manifest is opened on `VimEnter`, after your config and plugins have loaded.
Files it opens trigger the usual autocommands (filetype detection, plugins).

## Manifest

One JSON object. `version` is `1`. Paths must be absolute and are treated as
data: they are escaped before use, never expanded. Unknown fields are ignored.

| `kind`    | Fields                                     | Opens                                                                                       |
|-----------|--------------------------------------------|---------------------------------------------------------------------------------------------|
| `files`   | `root`: directory                          | `:cd` to `root`, then `root` in the file browser (netrw by default)                         |
| `file`    | `path`: file, `line`: optional integer ≥ 1 | `path` with the cursor on `line` (default 1; past the end means the last line)              |
| `diff`    | `path`: file, `base`: file                 | `base` (left, read-only) and `path` (right, editable) side by side in diff mode, cursor in `path` |
| `changes` | `changes`: non-empty list of changed files | the list in the quickfix window, the first file opened like `diff`                          |

```json
{ "version": 1, "kind": "diff", "path": "/work/repo/src/main.c", "base": "/tmp/astro/base/src/main.c" }
```

An invalid manifest (wrong version, unknown kind, relative or missing path, bad
line, invalid change entry, invalid `context`) opens nothing and shows an
`astro-editor:` error.

Any kind may also carry a `context` object declaring where `:AstroContext`
may send context messages; see [Context messages](#context-messages).

### Changed files

Each `changes` entry is an object:

- `status`: `modified`, `renamed`, `added` or `deleted`. Any other status is
  refused.
- `name`: shown for the entry in the quickfix list, for example the file's
  path in the repository. Non-empty text without control characters; it is
  only displayed, never used as a path.
- `path`: the changed file, opened editable on the right. Omitted for
  `deleted`, which is compared with an empty read-only buffer.
- `base`: the file before the change, read-only on the left. Required for
  `modified`, `renamed` and `deleted`; omitted for `added`, which is compared
  with an empty buffer. An explicit `null` counts as omitted, for `path` and
  `base` alike.

A file may appear only once in the list, as a `path` or a `base`.

```json
{ "version": 1, "kind": "changes", "changes": [
  { "status": "modified", "name": "src/main.c", "path": "/work/repo/src/main.c", "base": "/tmp/astro/base/src/main.c" },
  { "status": "added", "name": "src/new.c", "path": "/work/repo/src/new.c" }
] }
```

A quickfix jump to another entry replaces the previous diff with that entry's
whole-file diff: `]q` / `[q` (`:cnext` / `:cprevious`), `<CR>` on an entry in
the quickfix window, `:cfirst`, `:cc 2`. Showing a listed file any other way
(`:split`, `:edit`, `<C-^>`) leaves your windows alone. Inside a diff, `]c` / `[c`,
`gg` / `G` and folds work as for `diff`. `:cclose` / `:copen` hide and show
the list.

## Context messages

`:AstroContext` sends what you are looking at to one destination the launch
manifest declared, for example Firstmate, the primary assistant or the agent
working in this worktree. It is only a handoff: Astro decides what reaches the
destination.

```json
{ "version": 1, "kind": "file", "path": "/work/repo/src/main.c", "line": 12,
  "context": {
    "outbox": "/run/astro/launch-42/outbox",
    "destinations": [
      { "id": "firstmate", "label": "Firstmate" },
      { "id": "primary", "label": "Primary Assistant" }
    ] } }
```

- `outbox`: an existing directory Astro reads messages from.
- `destinations`: 1 to 16 objects. `id` is 1 to 64 letters, digits, `.`, `_`
  or `-`, unique in the list; `label` is what you pick from, 1 to 80 bytes
  without control characters.

Without a `context` the command refuses. Usage:

- `:AstroContext` sends the cursor's location and line.
- In visual mode, `:AstroContext` (`:'<,'>AstroContext`) sends the selection,
  characterwise, linewise or blockwise. Any other range, such as
  `:%AstroContext`, sends those whole lines.
- `:AstroContext {id}` skips the destination prompt; an id the launch did not
  declare is refused. `<Tab>` completes declared ids.

The command asks for the destination, then an optional one-line note, then
`Send` or `Cancel`. Nothing is sent unless you pick `Send`; `<Esc>` at any
prompt, an empty choice or `Cancel` sends nothing. Prompts go through
`vim.ui.select` and `vim.ui.input`, so a picker plugin can replace them.

The text comes from the buffer as you see it, saved or not. A message is
refused when its text is over 64 KiB or its note over 4 KiB, and when the
outbox no longer exists.

Each `Send` adds exactly one file to the outbox, readable only by you:
`context-<pid>-<time>-<n>.json`, where `n` counts this editor's messages
from 1. It is written under a dot name and renamed into place, so a reader
that skips dot files only ever sees whole messages.

```json
{ "version": 1, "destination": "primary", "kind": "selection",
  "path": "/work/repo/src/main.c", "filetype": "c", "modified": true,
  "line": 12, "end_line": 14, "text": "…", "note": "why is this slow?" }
```

`kind` is `selection` (with `line` and `end_line`) or `location` (with `line`
and the cursor's byte column `col`). `path` is the buffer name, `null` for an
unnamed buffer. Lines and columns start at 1.

## Your config and plugins

Configure AstroEditor in `~/.config/astro-editor/init.lua` like any Neovim
config. Plugins work as usual, for example with Neovim's built-in `vim.pack`
(0.12+):

```lua
vim.pack.add({ 'https://github.com/owner/plugin' })
```

or as packages under `~/.config/astro-editor/pack/*/start/`.

## Tests

```sh
nvim -l tests/run.lua
```

Each case starts the real Neovim binary headless under a throwaway XDG home
with synthetic files. Tested with Neovim 0.12.

## License

MIT
