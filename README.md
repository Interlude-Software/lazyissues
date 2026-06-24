# lazyissues

A [lazygit](https://github.com/jesseduffield/lazygit)-style terminal UI for a **file-based, in-repository issue tracker**, right inside Neovim.

Issues, sub-issues, sprints and releases live as JSON files under an `Issues/`
folder in your repo. `lazyissues` browses and edits them directly — no server,
no API, no database. Because the data is plain files in the repo, your issues
branch, diff, review and merge exactly like code.

> Status: **v0.1** — works against the on-disk format below. A configurable
> field *schema* (so you can adapt it to your own tracker) is on the roadmap.

```
┌─ Issues — myrepo ──────────────────────────────────────────────────────────┐
│ [1] Scopes    │ [4] Issues  (All)              │ [5] Detail                  │
│ › All   (50)  │ ▾ ● Backend caching     [75%]  │ #a1b2c3  Task               │
│   Open  (15)  │     ✓ add cache layer          │ Backend caching system      │
│   Backlog     │     ● invalidation             │ ───────────────             │
│ [2] Sprints   │   ★ Sub-issue support          │ Status    Open              │
│ › Next  (12)  │   ◷ Fix radius in screen space │ Priority  High              │
│ [3] Releases  │                                │ Sprint    Next              │
│   (none)      │                                │ Comments (2)  Children (3)  │
├───────────────┴────────────────────────────────┴─────────────────────────────┤
│  e edit   c comments   o new   O child   D del   P re-parent   / find   ? help│
└───────────────────────────────────────────────────────────────────────────────┘
```

## Features

- **lazygit-style panels** — Scopes / Sprints / Releases on the left, an issue
  **tree** (with nested sub-issues) in the centre, a detail pane on the right.
- **Full CRUD** — create / edit / delete issues, sub-issues, comments, sprints
  and releases, all from a discoverable edit menu (`e`).
- **Faithful, idempotent writes** — files are serialized to match the canonical
  on-disk format byte-for-byte, so edits produce minimal, clean git diffs.
- **Branch-edit markers** — issues whose files changed on the current branch
  (vs. the default branch, or in the working tree) are flagged in the gutter.
- **Scoped views & search** — All / Open / Backlog, per-sprint (with
  All/Open/Closed), per-release, and free-text title search.
- **%-complete** roll-up for issues with sub-issues, release-notes preview,
  context-sensitive footer, `?` help with a colour legend.
- **Auto-reload** when Neovim regains focus (so changes made by other tools show
  up), and an **init screen** to scaffold an `Issues/` folder in a fresh repo.

## Requirements

- Neovim **0.10+** (uses `vim.system` / `vim.uv`)
- [`MunifTanjim/nui.nvim`](https://github.com/MunifTanjim/nui.nvim)
- `git` (optional — only for the branch-edit markers)

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "Interlude-Software/lazyissues",
  cmd = "LazyIssues",
  dependencies = { "MunifTanjim/nui.nvim" },
  keys = {
    { "<leader>i", "<cmd>LazyIssues<cr>", desc = "Issues" },
  },
  opts = {}, -- lazy calls require("lazyissues").setup(opts) for you
}
```

(`opts = {}` is optional — omit it and the defaults are used.)

## Usage

Open the tracker for the current repo with `:LazyIssues` (or `<leader>i`). If the
repo has no `Issues/` folder yet, you'll be offered a one-key setup screen.

### Keymaps (inside the UI)

| Key | Action |
|-----|--------|
| `Tab` / `S-Tab`, `1`–`5` | cycle / jump panels |
| `j` `k` | move · `<Space>` expand/collapse sub-issues |
| `<CR>` | select scope/sprint/release · open issue |
| `/` | search by title · `r` reload · `?` help · `q` quit |
| **Issues:** `e` | **edit menu** (all fields + actions) |
| `c` | comments (add/delete) |
| `o` / `O` | new issue / new child issue |
| `D` / `P` | delete / re-parent |
| quick: `s` `p` `t` `a` `m` | status / priority / type / assignee / sprint |
| **Sprints/Releases:** `o` / `e` | new / edit (status, sprint links, notes) |

## On-disk format

`lazyissues` reads and writes a per-repo data root at `<repo>/Issues/`:

```
Issues/
  Issues/<guid>/issue.json            # an issue
  Issues/<guid>/<guid>/issue.json     # a sub-issue (folder nesting, any depth)
  Sprints/<guid>/sprint.json
  Releases/<guid>/release.json
```

An `issue.json` looks like:

```json
{
  "Id": "…", "Type": "Task", "Title": "…", "Description": "…",
  "SprintId": "…", "Status": "Open", "Priority": "Medium",
  "Reporter": "", "Assignee": "", "CreatedAt": "…", "UpdatedAt": null,
  "Tags": [], "Comments": [], "ReleaseNoteType": "None", "ReleaseNote": ""
}
```

Files are written PascalCase, 2-space indented, enums as strings — matching the
format produced by the reference tracker, so the two stay diff-compatible.

## Configuration

```lua
require("lazyissues").setup({
  width = 0.92,         -- float width as a fraction of the editor
  height = 0.88,        -- float height
  auto_refresh = true,  -- reload from disk on FocusGained
  assignees = { "Unassigned", "David", "Lewis", "Claude" },
  comment_authors = { "David", "Lewis", "Claude" },
})
```

> **Roadmap:** a field *schema* config to make the issue fields, enums, colours
> and lifecycle fully customisable for trackers other than the default format.

## License

[MIT](./LICENSE) © Interlude Software Ltd
