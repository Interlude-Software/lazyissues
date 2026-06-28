# lazyissues

A [lazygit](https://github.com/jesseduffield/lazygit)-style terminal UI for a **file-based, in-repository issue tracker**, right inside Neovim.

Issues, sub-issues, sprints and releases live as JSON files under an `Issues/`
folder in your repo. `lazyissues` browses and edits them directly — no server,
no API, no database. Because the data is plain files in the repo, your issues
branch, diff, review and merge exactly like code.

```
┌─ Issues — myrepo ──────────────────────────────────────────────────────────┐
│ [1] Scopes    │ [4] Issues  (All)              │ [5] Detail                  │
│ › All   (50)  │ ├── ● Backend caching   [75%]  │ a1b2c3d4-...   Task         │
│   Open  (15)  │ │   ├── ✓ add cache layer      │ ─────────────────           │
│   Backlog     │ │   └── ● invalidation         │ Title     Backend caching   │
│ [2] Sprints   │ ├── ● Sub-issue support        │ ─────────────────           │
│ ▶ Next  (12)  │ └── ● Fix radius               │ Status    Open              │
│ [3] Releases  │                                │ Priority  High              │
│   (none)      │                                │ Comments (2)  Children (3)  │
├───────────────┴────────────────────────────────┴─────────────────────────────┤
│  e edit   c comments   o new   O child   D del   P re-parent   / find   ? help│
└───────────────────────────────────────────────────────────────────────────────┘
```

## Features

- **lazygit-style panels** — Scopes / Sprints / Releases on the left, an issue
  **tree** (with nested sub-issues and classic connectors) in the centre, a
  detail pane on the right.
- **Customisable schema** — on first init, pick which fields your issues have
  from a predefined list (or edit the template later with `E`). Enum fields
  store their allowed values. Adding a field backfills existing issues;
  removing one prompts whether to delete the data.
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
repo has no `Issues/` folder yet, you'll be offered a setup screen where you
choose which fields your issues should have.

### Keymaps (inside the UI)

| Key | Action |
|-----|--------|
| `Tab` / `S-Tab`, `1`–`5` | cycle / jump panels |
| `j` `k` | move · `<Space>` expand/collapse · `zR` / `zM` expand/collapse all |
| `<CR>` | select scope/sprint/release · open issue |
| `/` | live filter (title, id, assignee, tags, description) |
| `f` / `F` | filter by field value / fuzzy-jump to any issue |
| `gs` / `gS` | sort issues / sprint stats |
| `B` | **kanban board** (columns by status; `<` `>` move cards) |
| `]c` / `[c` | next / prev issue edited on this branch |
| `r` reload · `?` help · `q` quit · `E` | **edit template** |
| **Issues:** `e` | **edit menu** (all fields + actions) |
| `c` | comments (add/delete) · `K` preview description |
| `o` / `O` | new issue / new child issue |
| `D` / `P` | delete / re-parent (with filterable picker) |
| `x` / `X` / `b` | mark / clear marks / bulk action on marked |
| `y` / `gf` | yank issue id / open raw `issue.json` |
| quick: `s` `S` `p` `t` `a` `m` | status / cycle status / priority / type / assignee / sprint |
| **Sprints/Releases:** `o` / `e` | new / edit (status, sprint links, notes, export) |

## Template

When you initialise a new project, `lazyissues` saves your field choices to
`Issues/template.json`. This file defines which fields each issue has, their
types, and allowed values for enum fields.

Press `E` at any time to edit the template. When you add a field, you'll be
prompted for a default value and all existing issues are backfilled. When you
remove a field, you choose whether to delete the data from existing issues or
keep it.

The template is optional — without one, `lazyissues` uses a classic set of
hardcoded fields.

### Predefined fields

| Field | Type | Default values |
|-------|------|----------------|
| Type | enum | Bug, Feature, Task, Improvement |
| Title | string | |
| Description | string | |
| Status | enum | Open, InProgress, Resolved, Closed |
| Priority | enum | Low, Medium, High, Critical |
| SprintId | string | |
| Reporter | string | |
| Assignee | string | |
| Tags | list | |
| Comments | list | |
| ReleaseNoteType | enum | None, Public |
| ReleaseNote | string | |
| DueDate | date | (system-managed) |
| Estimate | number | |
| Labels | list | |
| Environment | enum | Dev, Staging, Prod |
| Severity | enum | Cosmetic, Minor, Major, Critical |
| Resolution | enum | Fixed, WontFix, Duplicate, CannotReproduce |

System fields (`Id`, `CreatedAt`, `UpdatedAt`) are always present and
auto-managed.

## On-disk format

`lazyissues` reads and writes a per-repo data root at `<repo>/Issues/`:

```
Issues/
  template.json                         # field schema (optional)
  Issues/<guid>/issue.json              # an issue
  Issues/<guid>/<guid>/issue.json       # a sub-issue (folder nesting, any depth)
  Sprints/<guid>/sprint.json
  Releases/<guid>/release.json
```

Files are written PascalCase, 2-space indented, enums as strings — matching the
format produced by the reference tracker, so the two stay diff-compatible.

## Configuration

```lua
require("lazyissues").setup({
  width = 0.92,         -- float width as a fraction of the editor
  height = 0.88,        -- float height
  auto_refresh = true,  -- reload from disk on FocusGained
  assignees = { "Unassigned", "Alice", "Bob" },
  comment_authors = { "Alice", "Bob" },
})
```

## License

[MIT](./LICENSE) © Interlude Software Ltd
