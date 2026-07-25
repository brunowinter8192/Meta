# Space-Move Probe — macOS 15.7.7 (Sequoia, Build 24G720)

**Date:** 2026-05-29  
**Purpose:** Empirically determine which private API on macOS 15.7 can move a window (TextEdit) to
a non-active Space. Basis for migrating `desktop_targeting.py` away from
`CGSMoveWindowsToManagedSpace`.

## Setup

- System: macOS 15.7.7 Sequoia, ARM64 (Apple Silicon)
- Python: Homebrew Python 3.14.3 (`/opt/homebrew/bin/python3`)
- PyObjC: **not installed** → pure ctypes + raw `objc_msgSend` style (identical to `desktop_targeting.py`)
- Permissions: `AXIsProcessTrusted = True` (Accessibility), Screen Recording active
  (CGWindowListCopyWindowInfo returns 290 windows)
- Window detection: before/after diff via `CGWindowListCopyWindowInfo`, new window via
  AppleScript `tell application "TextEdit" to make new document` (robust; `open -a TextEdit`
  is fragile when the app is already running)
- Verification: `SLSCopySpacesForWindows(my_cid, 7, [wid])` correctly returns `[active_space]`
  before the move — works for TextEdit window WIDs from CGWindowList

## Methods tested

### Test A — `CGSMoveWindowsToManagedSpace` (CoreGraphics)

```
Library:   /System/Library/Frameworks/CoreGraphics.framework/CoreGraphics
Signature: CGSMoveWindowsToManagedSpace(cid, window_array, space_id)
desktop_targeting.py uses exactly this API (_move_windows_to_space)
```

- **before-space:** `[2119]` (active space, correct per SLSCopySpacesForWindows)
- **after-space:** `[2119]` (unchanged)
- **Return code:** `0x16000000` — not a valid OSStatus → function is likely void; restype=None
  in desktop_targeting.py confirms this
- **Result: FAIL** — no-op on macOS 15.7. Confirms the kasper/phoenix research:
  "only works prior to macOS 14.5"

### Test B — `SLSMoveWindowsToManagedSpace` (SkyLight, own connection)

```
Library:   /System/Library/PrivateFrameworks/SkyLight.framework/SkyLight
Signature: SLSMoveWindowsToManagedSpace(cid, window_array, space_id)
cid = SLSMainConnectionID() — the probe.py process's own connection
```

- **before-space:** `[2119]` (correct)
- **after-space:** `[2119]` (unchanged)
- **Return code:** `0x57A00000` — not a valid OSStatus → function is likely void
- **Result: FAIL** — window stays on the active space. Silently ignored.

### Test C — `SLSMoveWindowsToManagedSpace` (SkyLight, TextEdit owner connection)

```
TextEdit PID → PSN via Carbon GetProcessForPID → SLSGetConnectionIDForPSN
SLSConnectionGetPID(te_cid) == TextEdit PID: roundtrip verified ✓
te_cid = 428707
```

- **before-space:** `[2119]`
- **after-space:** `[2119]`
- **Result: FAIL** — no move even with the owner connection (TextEdit's own SLS connection).
  The connection ID is not the missing puzzle piece.

### Test stage 1b — `SLSBridgedMoveWindowsToManagedSpaceOperation` directly

```
Class present:      SLSBridgedMoveWindowsToManagedSpaceOperation ← objc_getClass returns non-nil
Dispatcher missing: SLSPerformAsynchronousBridgedWindowManagementOperation ← MISSING in SkyLight
Attempt: [[SLSBridgedMoveWindowsToManagedSpaceOperation alloc] initWithWindows:wids spaceID:target]
         then call .start (NSOperation route without a queue)
```

- **Result: CRASH (SIGSEGV, exit 139)** — the operation class exists, but calling `start`
  directly without the async-operation dispatcher segfaults. The class strictly requires
  `SLSPerformAsynchronousBridgedWindowManagementOperation` as dispatch context, which is
  **missing** on macOS 15.7 (symbol not exported from SkyLight).

## Available symbols (macOS 15.7 SkyLight)

| Symbol | Status | Note |
|--------|--------|------|
| `SLSMoveWindowsToManagedSpace` | FOUND | stage 2 — silent no-op |
| `SLSPerformAsynchronousBridgedWindowManagementOperation` | **MISSING** | stage 1 dispatcher |
| `SLSBridgedMoveWindowsToManagedSpaceOperation` (class) | FOUND | crash without dispatcher |
| `SLSCopySpacesForWindows` | FOUND | verification works |
| `SLSGetActiveSpace` | FOUND | |
| `SLSMainConnectionID` | FOUND | |
| `SLSGetConnectionIDForPSN` | FOUND | |
| `SLSConnectionGetPID` | FOUND | |
| `CGSMoveWindowsToManagedSpace` | FOUND | no-op as of macOS 14.5 |
| `CGSCopySpacesForWindows` | FOUND | |
| `CGSGetWindowWorkspace` | FOUND | returns rc=0, out=0 for foreign windows |

## Window detection (robustness)

**before/after diff via `CGWindowListCopyWindowInfo`:** robust. The diff reliably detects new
windows as long as the app does not open multiple windows at once.

**Critical bug documented:** `open -a TextEdit` without the `-n` flag opens no new window when
TextEdit is already running — it only activates the app. The diff then finds no delta and times out.
Fix: AppleScript `make new document` always creates exactly one new window.

**Frontmost-window variant:** not robust — when the app already has windows, the "frontmost"
window is not necessarily the newly opened one. Before/after diff remains the correct approach.

## Verification method

`SLSCopySpacesForWindows(my_cid, 7, [wid])` works for TextEdit window WIDs
(from `CGWindowListCopyWindowInfo`) from a process with Screen Recording + Accessibility.
Returns `[space_id]` correctly. Used as the primary method.

`CGSGetWindowWorkspace(my_cid, wid, &outSpace)` returns `rc=0, out=0` for windows of foreign
processes — unusable.

## Diagnosis: why does SLSMoveWindowsToManagedSpace fail?

All four approaches (A/B/C/stage 1b) fail despite Accessibility + Screen Recording.
Most likely cause: on macOS 15, `SLSMoveWindowsToManagedSpace` requires a
**private system entitlement** or the **Dock scripting addition** (yabai stage 3) to move
windows of foreign processes between Spaces.

yabai on macOS 13+ documents that space moves do not work without the scripting addition.
The scripting addition injects code into Dock.app, which holds the necessary
`com.apple.private.skylight.*` entitlement. An unprivileged Python application cannot
imitate these entitlements.

## Result matrix

| Method | PASS/FAIL | Comment |
|--------|-----------|---------|
| A: `CGSMoveWindowsToManagedSpace` | **FAIL** | no-op as of macOS 14.5, confirmed |
| B: `SLSMoveWindowsToManagedSpace` (own cid) | **FAIL** | silently no move |
| C: `SLSMoveWindowsToManagedSpace` (owner cid) | **FAIL** | connection ID irrelevant |
| Stage 1b: `SLSBridgedMoveWindowsToManagedSpaceOperation.start` | **CRASH** | dispatcher MISSING |

**None of the tested methods moves a window on macOS 15.7.**

## Implication for desktop_targeting.py

Move-after-create is not feasible with pure ctypes APIs from an unprivileged process on
macOS 15.7. Alternative strategy for `show`/`tmux_spawn.sh`:

**Switch-open-switch:** temporarily switch the active Space to the target Space (via
`CGSSetWorkspace` or similar), open the app, switch back. Drawback: visible Space animation.
This API strategy was not tested in the probe; it would be the next empirical step.
