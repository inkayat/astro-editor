# astro-editor

Plain Neovim runtime for AstroEditor.

AstroEditor is stock Neovim with its own profile: no LazyVim, no plugin
manager, no changes to your existing Neovim config. This repository holds the
small Lua runtime that opens what Astro asks for (a folder, a file at a line,
a whole-file diff, or a list of changed files) and then gets out of the way.
Navigation is ordinary Neovim: netrw for folders, `]c` / `[c`, `do` / `dp`,
`gg` / `G` and folds in diffs, `]q` / `[q` through changed files.

The runtime never runs git, a shell or any other program. Diffs use Neovim's
built-in diff.

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
line, invalid change entry) opens nothing and shows an `astro-editor:` error.

### Changed files

Each `changes` entry is an object:

- `status`: `modified`, `renamed` or `added`. Any other status is refused; a
  deleted file, for example, has no file left to open.
- `name`: shown for the entry in the quickfix list, for example the file's
  path in the repository. Non-empty text without control characters; it is
  only displayed, never used as a path.
- `path`: the changed file, opened editable on the right.
- `base`: the file before the change, read-only on the left. Required for
  `modified` and `renamed`; omitted for `added`, which is compared with an
  empty buffer.

A file may appear only once in the list, as a `path` or a `base`.

```json
{ "version": 1, "kind": "changes", "changes": [
  { "status": "modified", "name": "src/main.c", "path": "/work/repo/src/main.c", "base": "/tmp/astro/base/src/main.c" },
  { "status": "added", "name": "src/new.c", "path": "/work/repo/src/new.c" }
] }
```

Every quickfix jump to a listed file replaces the previous diff with that
file's whole-file diff: `]q` / `[q` (`:cnext` / `:cprevious`), `<CR>` on an
entry in the quickfix window, `:cfirst`, `:cc 2`. Inside a diff, `]c` / `[c`,
`gg` / `G` and folds work as for `diff`. `:cclose` / `:copen` hide and show
the list.

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
