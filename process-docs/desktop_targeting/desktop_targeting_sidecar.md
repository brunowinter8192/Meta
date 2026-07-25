# desktop_targeting: consume menubar cwd_desktop sidecar

**Date:** 2026-05-29  
**Branch:** blank-desktop-targeting  
**Commit:** feat(desktop): consume menubar cwd_desktop sidecar + blank logging

## Problem

`find_caller_main_space()` used a fragile four-step chain to resolve the caller's Mission Control Desktop:

1. `_read_cwd_uuid_map()` — cwd→UUID from `ghostty_cwd_uuid.json`
2. `_ghostty_uuid_to_window_name()` — AppleScript UUID→window-name lookup
3. `_ghostty_pid()` + `_windows_by_name_for_pid()` — CGWindowList name-match against Ghostty PID
4. `_spaces_for_wid()` — CGSCopySpacesForWindows on the matched wid

Failure modes:
- `kCGWindowName` not populated without spinner-normalize → `n_cand=0`
- No SkyLight TCC bypass → AppleScript UUID lookup fails in some sandbox contexts
- Name-match requires `len(wids)==1` — any window-title ambiguity → hard fail

Both call paths (`bin/show`, `tmux_spawn.sh:open_tmux_viewer`) suppressed all output with `>/dev/null 2>&1`, making failures undiagnosable.

## Solution

### Sidecar schema contract

Monitor_CC menubar publishes its verified detection result:

```
Path:  ~/Library/Application Support/com.brunowinter.monitor_cc_menubar/cwd_desktop.json
Shape: {"<cwd>": {"space_id": <int>, "desktop_no": <int>}}
```

Semantics: last-known-good per cwd. Entries are stable — the menubar only writes valid `space_id`s.

### New `find_caller_main_space()` flow

Kept:
- `_find_claude_ancestor(caller_pid)` → `claude_pid`  (parent-PID walk)
- `_cwd_of_pid(claude_pid)` → `cwd`  (lsof cwd fd)

Replaced (entire name-match chain → single JSON lookup):
```python
entry = _read_cwd_desktop_map().get(cwd)
space_id, desktop_no = entry["space_id"], entry["desktop_no"]
```

Fallback (sidecar miss): `CGSGetActiveSpace` as best-effort space_id. Logged with `sidecar=miss:<reason>`.

### Dead code removed

| Symbol | Reason |
|--------|--------|
| `_read_cwd_uuid_map()` | read old UUID map |
| `_ghostty_uuid_to_window_name()` | AppleScript name query |
| `_ghostty_pid()` | Ghostty process search |
| `_windows_by_name_for_pid()` | CGWindowList name-match |
| `_spaces_for_wid()` | CGSCopySpacesForWindows per-wid |
| `_CWD_UUID_FILE` | old constant |
| `_CGS_SPACE_MASK` | only used by `_spaces_for_wid` |
| `_CG.CGSCopySpacesForWindows` binding | same |

### Detect-before-disturb reorder

Previously: open triggered → `wait-and-move` called → `find_caller_main_space` inside.  
Now: `find-caller-desktop` resolves `space_id` **before** the open, then `wait-and-move-space` takes the pre-resolved `space_id`.

New CLI subcommand: `wait-and-move-space <space_id> <owner_name> [timeout] [op]`

**`bin/show`:**
```bash
_space_id=$(python3 "$_DESKTOP_HELPER" find-caller-desktop "$PPID" show 2>/dev/null | cut -d' ' -f1)
open -a "CotEditor" "$f"
python3 "$_DESKTOP_HELPER" wait-and-move-space "$_space_id" "$app_name" 4 show &
```

**`tmux_spawn.sh`** (both spawn + revive call sites):
```bash
_dt_space_id=$(python3 "$_dt_helper" find-caller-desktop "$PPID" spawn 2>/dev/null | cut -d' ' -f1)
open_tmux_viewer "$session" "$_dt_space_id" &
```
`open_tmux_viewer` accepts `$2=space_id`, passes to `wait-and-move-space` internally.

### Blank log sink

Path: `~/Library/Logs/blank/desktop_targeting.log`  
Format: `<ISO-timestamp> op=<op> caller_pid=<n> claude_pid=<n> cwd=<path> sidecar=<hit|miss:reason> space_id=<n>`  
Both call paths log resolution + move outcomes. Silent failures are now diagnosable.

## Open issues (not implemented)

1. **Worker-calling-`show` routing**: When a worker calls `show`, `_find_claude_ancestor` returns the worker's own claude PID. The sidecar entry for the worker's cwd resolves the worker's Desktop, not the parent Main's Desktop. Routing decision (follow worker cwd vs. parent-main cwd) is deferred.

2. **Multi-new-window disambiguation**: `wait_for_new_windows_and_move` moves all new layer-0 windows in the poll window. Concurrent app opens from other sources may be incorrectly moved. Left for a future targeted fix.

## Live verify 2026-05-29 — routing does not take effect (two bugs)

End-to-end test (Opus calls `show <md>`, user on Desktop 1, caller main session on Desktop 2): the md opened on Desktop 1 (active desktop) instead of 2 (caller). Routing does not work. Two separate causes.

### Bug 1 — `show` cannot find its helper (symlink path)

`show` is symlinked: `~/.local/bin/show → Meta/blank/bin/show`. The script derives `_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"` — which does NOT follow the symlink. When invoked via PATH, `$0=~/.local/bin/show`, so `_DESKTOP_HELPER=~/.local/bin/../src/desktop/desktop_targeting.py = ~/.local/src/desktop/desktop_targeting.py` → **does not exist** → `[ -f "$_DESKTOP_HELPER" ]` false → `_space_id` stays empty → `find-caller-desktop` is never called (hence no `op=show` log entry) → `wait-and-move-space` is never called → CotEditor stays on the active desktop.

Verified: a direct helper call `find-caller-desktop $$` correctly returns `780 2` (`sidecar=hit`) — the resolution is intact, ONLY the path in `show` is wrong.

**Fix:** resolve the symlink in `show` before `dirname` runs (while-`readlink` loop or `python3 -c "os.path.realpath"`). Affects ONLY `show`; `tmux_spawn.sh` finds the helper by a different route (spawn logs show `sidecar=hit space_id=780`).

**Fix applied 2026-05-29** (`bin/show` lines 20-22): `$0` is resolved via `python3 -c 'os.path.realpath'` before `dirname`. `python3` is already a hard dependency of the script, so this is consistent with (and preferred over) the `readlink` loop. Verified (without a CotEditor open): invocation simulation with `$0=~/.local/bin/show` → `_DESKTOP_HELPER` resolved to `Meta/blank/bin/../src/desktop/desktop_targeting.py`, `[ -f ]` true. The helper is now reached.

End-to-end live verify 2026-05-29T16:42 (user on the active desktop, `~/.local/bin/show <md>` from the Monitor_CC session): for the first time two `op=show` log lines — `op=show caller_pid=80872 claude_pid=80872 cwd=Monitor_CC sidecar=hit space_id=780` (helper runs, caller desktop correctly resolved) + `op=show wait-and-move-space space_id=780 owner='CotEditor' move=no-new-window`. **Bug 1 thereby fully confirmed** (previously NEVER an `op=show` entry). The file still landed on the active desktop — the symptom is now caused purely by Bug 2.

### Bug 2 — `move=no-new-window` (separate, pending)

On worker spawns (helper found, `space_id 780` correctly resolved), `wait_for_new_windows_and_move` still reports `move=no-new-window` (logs 02:01 + 02:59). The new window is not detected as an `after - before` delta within the poll window → no move. Suspicion: CGWindowList visibility (TCC for blank's `python3`), or the target window already existed (no delta), or timing. Cause pending.

**Confirmed for `show` 2026-05-29T16:42** (after the Bug-1 fix): `op=show wait-and-move-space space_id=780 owner='CotEditor' move=no-new-window`. Reproduced across three paths — spawn (Ghostty), show (CotEditor), an older dryrun (CotEditor) — all `move=no-new-window`. Systematic problem in `wait_for_new_windows_and_move` (the `after - before` delta does not detect the new window), not app- or path-specific.

### GitHub research 2026-05-29 — the move API is dead on macOS 15

Verification of whether any API exists to open a window directly on a non-active Space, and whether our move API is still alive. System: **macOS 15.7.7 (Sequoia, Build 24G720)**.

**Finding 1 — no direct open-on-space.** There is no public API to open a window directly on a specific non-active Space. All examined window managers (yabai 28.9k★, kasper/phoenix, lwouis/alt-tab-macos, bryancostanich/lattice, linearmouse) create the window and **move it afterwards** via private SkyLight/CoreGraphics APIs. This confirms: `open` always lands on the active Space; move-after-create is the only route.

**Finding 2 — `CGSMoveWindowsToManagedSpace` is dead as of macOS 13.6/14.5/15.0.** This is exactly the API our helper uses (`_move_windows_to_space` → `_CG.CGSMoveWindowsToManagedSpace`). `kasper/phoenix` `Phoenix/PHSpace.m:218-228` explicitly gives up in `moveWindows`: `if isOperatingSystemAtLeastVentura136 || isOperatingSystemAtLeastSonoma145 || isOperatingSystemAtLeastSequoia: NSLog("deprecated"); return;` — comment lines 64-65: *"only works prior to macOS 14.5"*. On macOS 15.7 the move call is thus presumably a no-op even where window detection works. (The Bug-2 symptom `move=no-new-window` currently occurs BEFORE the move call — detection fails first; the dead move is a second, not-yet-reached layer.)

**Finding 3 — the modern route (yabai, works on macOS 15).** `asmvik/yabai` `src/space_manager.c:665-688` (`space_manager_move_window_to_space`), three-stage fallback:
1. **`SLSPerformAsynchronousBridgedWindowManagementOperation`** + `objc_getClass("SLSBridgedMoveWindowsToManagedSpaceOperation")` / `initWithWindows:spaceID:` — the modern SkyLight "bridged" operations path, WITHOUT scripting addition/SIP. Preferred on current macOS.
2. **`SLSMoveWindowsToManagedSpace`** (the SkyLight `SLS` variant, NOT the CoreGraphics `CGS` variant we use).
3. Scripting addition (`scripting_addition_move_window_to_space`, needs partial SIP disable + Dock injection) or `SLSSpaceSetCompatID`+`SLSSetWindowListWorkspace` with a magic compat ID as the last fallback.

**Consequence for Bug 2.** Two layers: (a) window detection (`after - before`) fails, (b) even the move (`CGSMoveWindowsToManagedSpace`) is dead on macOS 15. Both must be addressed. Migrating the move API from CoreGraphics `CGS` → SkyLight `SLSPerformAsynchronousBridgedWindowManagementOperation` is an architecture alternative → belongs in a `dev/` probe, NOT directly in `src/`. The probe must actually move a window to a target Space on macOS 15.7 before `desktop_targeting.py` is touched.

**Sources (GitHub):** `kasper/phoenix` Phoenix/PHSpace.m; `asmvik/yabai` src/space_manager.c; `beeper/BetterSwiftAX`, `bryancostanich/lattice`, `linearmouse/linearmouse` (CGSSpace.h header declarations).

### Probe result 2026-05-29 — all move APIs fail from an unprivileged process

**Probe:** `dev/desktop_targeting/probe.py` + report in `dev/desktop_targeting/md/space_move_probe_2026-05-29.md`. Full protocol there.

**Environment:** macOS 15.7.7, Homebrew Python 3.14.3, PyObjC NOT available → pure ctypes + raw objc_msgSend. Accessibility (`AXIsProcessTrusted=True`) + Screen Recording (290 windows via CGWindowList) both active — no permission problem.

**Symbol inventory on macOS 15.7:**
- `SLSMoveWindowsToManagedSpace` — FOUND (stage 2)
- `SLSPerformAsynchronousBridgedWindowManagementOperation` — **MISSING** (stage 1 dispatcher)
- `SLSBridgedMoveWindowsToManagedSpaceOperation` (ObjC class) — FOUND, but CRASH without the dispatcher
- `SLSCopySpacesForWindows`, `SLSGetActiveSpace`, `SLSMainConnectionID`, `SLSGetConnectionIDForPSN` — all FOUND

**Test matrix:**

| Method | Result | Detail |
|--------|--------|--------|
| A: `CGSMoveWindowsToManagedSpace` | **FAIL** | no-op, confirmed; rc=0x16000000 (void function) |
| B: `SLSMoveWindowsToManagedSpace` (own cid) | **FAIL** | silent, window stays on active Space |
| C: `SLSMoveWindowsToManagedSpace` (TextEdit owner cid via `SLSGetConnectionIDForPSN`) | **FAIL** | connection ID is not the missing element |
| Stage 1b: `SLSBridgedMoveWindowsToManagedSpaceOperation.start` directly | **CRASH** | SIGSEGV; the class needs `SLSPerformAsynchronousBridgedWindowManagementOperation` as dispatch context |

**Diagnosis:** `SLSMoveWindowsToManagedSpace` runs without error but moves nothing — a silent no-op for unprivileged processes. Probable cause: requires a private system entitlement (`com.apple.private.skylight.*`) or the yabai Dock scripting addition (stage 3, needs SIP modification). Not reachable from an unprivileged Python process.

**Window detection:** before/after diff via `CGWindowListCopyWindowInfo` is robust. `open -a TextEdit` without `-n` opens no new window when the app is already running → fix: AppleScript `make new document`.

**Consequence:** move-after-create is not feasible on macOS 15.7 from Python/ctypes without SIP modification.

### Re-verification 2026-05-29 (Opus + screenshots) — worker's measurement method was unreliable, result confirmed anyway

Trigger: user observation during the live test — TextEdit started (dock icon) but no window visible on his desktop; suspicion that the Sonnet worker had erred. Opus re-checked independently.

**Finding 1 — the worker's verification was broken.** The probe determined PASS/FAIL solely via `SLSCopySpacesForWindows`. For freshly created windows this API stubbornly reports the *active* Space, regardless of where the window really is. Screenshot evidence: active desktop = 2 (space 780), API reports the window on [780], but a full-screen screenshot of the active desktop shows **no** TextEdit window. The worker's `after==before==target?` logic was measuring noise.

**Finding 2 — an independent method confirms: the move is dead.** Reliable signal instead of the readback API: `CGWindowListCopyWindowInfo` with `kCGWindowListOptionOnScreenOnly` (=1) lists only windows of the *active* desktop. Decisive test: open a window (does NOT land on the active desktop) → pull it to the active desktop via `SLSMoveWindowsToManagedSpace` → check the on-screen list AND a full-screen screenshot. Result: the window stayed invisible (not in the on-screen list, not in the screenshot). The move moves nothing. A per-window direct capture `screencapture -l<wid>` shows the window cleanly (it exists), but it cannot be placed on the active desktop. **The worker's conclusion was right via a wrong route.**

**Finding 3 — reliable methods for future tests:** (a) window existence/content: `screencapture -x -l<wid>` (works across spaces). (b) "is the window on the active desktop?": membership in `CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, …)`. (c) desktop↔space_id map: `CGSCopyManagedDisplaySpaces` (order = desktop number), active via `CGSGetActiveSpace`. Do NOT rely on `SLSCopySpacesForWindows`/`CGSGetWindowWorkspace` for the live position of foreign windows.

**Finding 4 (side finding, open):** a new app window (`make new document`) does NOT open on the active desktop but where the app is "at home". Reproduced across several runs (active 2 or 5, window never there). Its own work item, separate from the move question — relevant if "open lands correctly" is ever assumed.

### Status: DEAD END — shelved (user decision 2026-05-29)

Option space exhausted: (1) move-after-open = dead without SIP (verified). (2) open directly on target Space = no API (GitHub research). (3) switch-open-switch = **rejected** (user does not want to be yanked to another desktop). (4) Dock scripting addition + partial SIP disable (yabai stage 3) = **rejected** (no security trade-off). (5) giving up auto-placement = **rejected** (loss of overview).

No non-SIP tool on macOS 15.7 satisfies "place silently without disturbing the user". Topic shelved. **Resumption:** when the Reddit/gh-cli research tools are more mature → a comprehensive re-research on macOS 15 space placement (new private APIs, possibly ScreenCaptureKit/Accessibility routes, entitlement options). Until then the symlink fix in `bin/show` (Bug 1) remains the only shipped result; desktop routing (Bug 2) is known non-functional on macOS 15.7.
