# Git Integration — Design

**Date:** 2026-07-09
**Status:** Approved (user directive: continue autonomously, delegate implementation to Codex)

## Problem

FileExplorer is a developer's file manager, yet it is blind to the one piece
of file state developers care about most: git. Finder and every macOS rival
are equally blind — surfacing repo state directly in the browser is the
clearest "best on macOS" differentiator this app can ship.

## Goal

- **Status badges:** a colored dot on each row/cell for files that are
  modified, staged, untracked, or conflicted in the enclosing git repo;
  folders aggregate their descendants' states.
- **Branch display:** the repo's current branch (and dirty count) in the
  pane's status bar whenever the pane folder is inside a repo.
- **Ignored-file awareness:** gitignored entries render dimmed, and a filter
  toggle hides them entirely (persisted like other filter fields).
- Zero cost outside repos; never blocks the UI; degrades silently if `git`
  is unavailable.

## Approach (chosen): one `git status` subprocess per repo, pure parser

A per-pane `GitStatusModel` (app-lifetime pattern) locates the repo root by
walking ancestors for `.git`, then runs
`git -C <root> status --porcelain=v2 --branch --ignored=matching -z`
off the main actor, and a **pure Core parser** (`GitStatusParser`) turns the
output into `GitRepoStatus` (branch, per-path `GitFileState`, ignored set).
Badges are resolved per row by pure lookup (`GitStatusIndex`) that also
aggregates folder states by path prefix. Refreshes ride the pane's existing
reload/watcher events, debounced.

**Rejected:** libgit2 (new dependency, overkill for read-only status);
per-file `git check-ignore` calls (subprocess per row); FSEvents-driven
.git watching (the pane watcher already fires on the interesting changes;
a .git/index watcher can come later if staleness annoys).

## Semantics decisions

- **Repo discovery:** nearest ancestor containing `.git` (dir or file —
  worktrees have a `.git` file). No repo → model idles with zero subprocess
  activity. Discovery result cached per pane folder.
- **States shown** (per path, priority order): `conflicted` >
  `staged` (index changed) > `modified` (worktree changed) > `untracked` >
  `ignored` > `clean`. Renames count as staged. Submodule entries treated as
  modified when dirty.
- **Badge rendering:** 7 pt dot after the filename (before tag dots):
  orange = modified, green = staged, blue = untracked, red = conflicted.
  Ignored entries get **no dot**; instead the row label renders at reduced
  opacity (0.5), same treatment as hidden files if a precedent exists.
- **Folder aggregation:** a folder shows the highest-priority state among
  descendants (conflicted > staged > modified > untracked). Ignored/clean
  descendants contribute nothing. The repo root folder itself, when listed
  in its parent, aggregates the whole repo.
- **Branch display:** status bar suffix "⎇ main · 3 changed" (branch from
  `# branch.head`; detached → short OID from `# branch.oid`, prefixed
  "detached "). Count = number of non-ignored changed paths.
- **Ignored filter:** `FilterState` gains optional `hideGitIgnored: Bool?`
  (decodeIfPresent-safe like `tags`); FilterBar gains a "Hide ignored"
  toggle that only appears when the pane is inside a repo. `FilterEngine`
  can't see git state, so PaneState applies the ignored-set subtraction
  alongside its existing filter application (verify where FilterEngine is
  invoked and subtract there).
- **Refresh triggers:** pane `navigate`/`reload`/watcher fire → debounced
  (250 ms) re-run; palette/menu "Refresh Git Status" not needed (watcher
  covers saves). Status output capped at 2 MB — larger repos drop badges
  beyond the cap but keep branch info (log nothing; this is cosmetic state).
- **Process hygiene:** `git` located via `/usr/bin/git` (CLT ships it);
  missing binary or nonzero exit → repo treated as absent. Runs detached
  (`Task.detached`), results hopped to the main actor; a generation counter
  discards stale results (same posture as DirectoryLoader).
- **Tree expansion:** badges work on nested rows for free (lookup by URL);
  expanded-subfolder contents are inside the same repo status snapshot.
- **Out of scope (YAGNI):** any write operation (stage/commit/checkout),
  multi-repo panes (only the repo containing the pane folder is consulted),
  diff previews, blame, and .git/index watchers.

## Components

| Unit | Kind | Responsibility |
|---|---|---|
| `GitStatusParser` (new, Core) | pure enum | porcelain-v2 + branch header + ignored parsing → `GitRepoStatus` |
| `GitStatusIndex` (new, Core) | pure struct | path → state lookup; folder prefix aggregation; ignored-set membership |
| `GitRepoLocator` (new, Core) | pure enum | ancestor walk for `.git` given an injectable `fileExists` closure |
| `GitStatusModel` (new, app or Core) | @MainActor @Observable | repo discovery cache, debounced subprocess runs, generation guard, published `GitRepoStatus?` |
| `PaneState` (modify) | @Observable | ignored-set subtraction in visible-entry pipeline; refresh hook calls |
| `FilterState` (modify) | Codable | optional `hideGitIgnored` |
| `FileEntryLabel` / `ThumbnailGridView` (modify) | SwiftUI | badge dot + ignored dimming |
| `PaneView` (modify) | SwiftUI | status-bar branch text; FilterBar toggle |

## Testing

Executable harness; `git` CLI is available on the machine, so integration
tests can `git init` real temp repos:
- `GitStatusParserTests`: fixture porcelain-v2 strings (ordinary/renamed/
  unmerged/untracked/ignored entries, branch header, detached head, empty),
  NUL-terminated parsing, 2 MB cap behavior.
- `GitStatusIndexTests`: file lookup, folder aggregation priority, repo-root
  aggregation, ignored membership, non-repo paths → clean.
- `GitRepoLocatorTests`: nested dirs, `.git` file (worktree), no repo.
- `GitStatusModelTests` (integration): `git init` temp repo, commit a file,
  modify/stage/add-untracked/gitignore variants, assert published states;
  non-repo folder → nil status; debounce coalesces rapid refreshes.
- `FilterState` round-trip + legacy decode for `hideGitIgnored`;
  `PaneState` test: ignored file disappears when toggle set (temp repo).
