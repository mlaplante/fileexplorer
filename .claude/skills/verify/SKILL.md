---
name: verify
description: Build, launch, and drive FileExplorer.app for runtime verification on this CLT-only, TCC-restricted machine.
---

# Verifying FileExplorer

Build the app bundle (release): `./Scripts/bundle.sh` → `build/FileExplorer.app`.

Drive a specific folder at launch by editing the persisted session before opening
(ALWAYS back it up first and restore after — it is the user's real session):

```bash
cp ~/Library/Application\ Support/FileExplorer/session.json /tmp/session-backup.json
python3 -c "
import json, os, sys
p=os.path.expanduser('~/Library/Application Support/FileExplorer/session.json')
d=json.load(open(p)); d['tabs'][0]['panes'][0]['path']=sys.argv[1]
json.dump(d, open(p,'w'), indent=1)" "<folder-to-open>"
open build/FileExplorer.app
```

Health checks (TCC blocks UI scripting and screencapture here — these are the
observable signals):
- `pgrep -x FileExplorer` + `ps -o rss=,%cpu= -p $(pgrep -x FileExplorer)` — alive, settled.
- `sample FileExplorer 2 | grep -A3 main-thread` — main thread in run loop, not hung.
- `ls ~/Library/Logs/DiagnosticReports | grep -i fileexplorer` — no new crash reports.
- Quit cleanly with `osascript -e 'tell application "FileExplorer" to quit'` (plain
  quit Apple event works without accessibility permission); confirm session.json was
  autosaved, then restore the backup.

Big test folders: the bench fixtures under
`~/Library/Caches/FileExplorerBench/full-v1-*/` (flat = 50k files, deep = 250k
entries, dupes = duplicate corpus). Regenerate with
`swift run -c release FileExplorerBench` if missing.

Menu-driven sheets (Find Duplicates, Disk Usage, archive browser) cannot be scripted
(TCC). Exercise their models via `swift run -c release FileExplorerBench --only
duplicate-scan|usage-scan` and leave sheet UI to a human spot-check.
