#!/usr/bin/env python3
"""Space-move probe — empirisch testen welche API auf macOS 15.7 Fenster auf einen
anderen Space verschiebt.

Für jeden Move-Test wird ein eigenes neues TextEdit-Dokument via AppleScript erstellt
→ keine Fenster-Kontamination zwischen Tests. Vor und nach dem Move wird der Space des
Fensters via CGSGetWindowWorkspace zurückgelesen → explizites PASS/FAIL.

Fehler aus Move-Calls werden NICHT gecatcht — Permission-Fehler (TCC) sollen
sichtbar sein.

Usage:
  python3 probe.py [--space <target_space_id>] [--debug]
"""

import argparse
import ctypes
import subprocess
import sys
import time
from typing import Dict, List, Optional, Set, Tuple

# ── Library handles ────────────────────────────────────────────────────────────

_CG  = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
_SL  = ctypes.CDLL('/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight')
_OBJ = ctypes.CDLL('/usr/lib/libobjc.A.dylib')

# CoreGraphics
_CG.CGSMainConnectionID.argtypes          = []
_CG.CGSMainConnectionID.restype           = ctypes.c_int32
_CG.CGSGetActiveSpace.argtypes            = [ctypes.c_int32]
_CG.CGSGetActiveSpace.restype             = ctypes.c_uint64
_CG.CGSCopyManagedDisplaySpaces.argtypes  = [ctypes.c_int32]
_CG.CGSCopyManagedDisplaySpaces.restype   = ctypes.c_void_p
_CG.CGSMoveWindowsToManagedSpace.argtypes = [ctypes.c_int32, ctypes.c_void_p, ctypes.c_uint64]
_CG.CGSMoveWindowsToManagedSpace.restype  = ctypes.c_int32
_CG.CGWindowListCopyWindowInfo.argtypes   = [ctypes.c_uint32, ctypes.c_uint32]
_CG.CGWindowListCopyWindowInfo.restype    = ctypes.c_void_p
# CGSCopySpacesForWindows: returns CFArrayRef of space IDs for given window IDs
_CG.CGSCopySpacesForWindows.argtypes      = [ctypes.c_int32, ctypes.c_int32, ctypes.c_void_p]
_CG.CGSCopySpacesForWindows.restype       = ctypes.c_void_p
# CGSGetWindowWorkspace: single-window space query (alternative verification)
_CG.CGSGetWindowWorkspace.argtypes        = [ctypes.c_int32, ctypes.c_uint32,
                                              ctypes.POINTER(ctypes.c_uint64)]
_CG.CGSGetWindowWorkspace.restype         = ctypes.c_int32

# SkyLight
_SL.SLSMainConnectionID.argtypes          = []
_SL.SLSMainConnectionID.restype           = ctypes.c_int32
_SL.SLSGetActiveSpace.argtypes            = [ctypes.c_int32]
_SL.SLSGetActiveSpace.restype             = ctypes.c_uint64
_SL.SLSMoveWindowsToManagedSpace.argtypes = [ctypes.c_int32, ctypes.c_void_p, ctypes.c_uint64]
_SL.SLSMoveWindowsToManagedSpace.restype  = ctypes.c_int32
_SL.SLSCopySpacesForWindows.argtypes      = [ctypes.c_int32, ctypes.c_int32, ctypes.c_void_p]
_SL.SLSCopySpacesForWindows.restype       = ctypes.c_void_p

# ObjC runtime
_OBJ.sel_registerName.restype  = ctypes.c_void_p
_OBJ.sel_registerName.argtypes = [ctypes.c_char_p]
_OBJ.objc_getClass.restype     = ctypes.c_void_p
_OBJ.objc_getClass.argtypes    = [ctypes.c_char_p]

# CFUNCTYPE refs — module-level to prevent GC from corrupting IMP table
_FT_vv   = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p)
_FT_vvv  = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p)
_FT_vvcp = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_char_p)
_FT_vvl  = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_long)
_FT_lvv  = ctypes.CFUNCTYPE(ctypes.c_long,   ctypes.c_void_p, ctypes.c_void_p)
_FT_pvv  = ctypes.CFUNCTYPE(ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p)
_FT_nvv  = ctypes.CFUNCTYPE(None,            ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p)

_IMP = ctypes.cast(_OBJ.objc_msgSend, ctypes.c_void_p).value

_DEBUG = False

def _dbg(msg: str):
    if _DEBUG:
        print(f"  [dbg] {msg}")

# ── ObjC message helpers ───────────────────────────────────────────────────────

def _sel(s: str):
    return _OBJ.sel_registerName(s.encode())

def _msg0(obj, s: str):
    return ctypes.cast(_IMP, _FT_vv)(obj, _sel(s))

def _msg1v(obj, s: str, a):
    return ctypes.cast(_IMP, _FT_vvv)(obj, _sel(s), a)

def _msg1cp(obj, s: str, a: bytes):
    return ctypes.cast(_IMP, _FT_vvcp)(obj, _sel(s), a)

def _msg1l(obj, s: str, a: int):
    return ctypes.cast(_IMP, _FT_vvl)(obj, _sel(s), ctypes.c_long(a))

def _msgl(obj, s: str) -> int:
    return ctypes.cast(_IMP, _FT_lvv)(obj, _sel(s))

def _msgp(obj, s: str):
    return ctypes.cast(_IMP, _FT_pvv)(obj, _sel(s))

def _nsstr(s: str):
    return _msg1cp(_OBJ.objc_getClass(b"NSString"), "stringWithUTF8String:", s.encode())

def _cf_count(arr) -> int:
    return _msgl(arr, "count")

def _cf_at(arr, i: int):
    return _msg1l(arr, "objectAtIndex:", i)

def _dict_val(d, key: str):
    return _msg1v(d, "objectForKey:", _nsstr(key))

def _dict_str(d, key: str) -> Optional[str]:
    v = _dict_val(d, key)
    if not v:
        return None
    r = _msgp(v, "UTF8String")
    return r.decode() if r else None

def _dict_long(d, key: str) -> Optional[int]:
    v = _dict_val(d, key)
    return _msgl(v, "intValue") if v else None

def _make_uint_array(values: List[int]):
    NSMutableArray = _OBJ.objc_getClass(b"NSMutableArray")
    NSNumber       = _OBJ.objc_getClass(b"NSNumber")
    arr = ctypes.cast(_IMP, _FT_vv)(NSMutableArray, _sel("array"))
    for v in values:
        n = ctypes.cast(_IMP, _FT_vvl)(NSNumber, _sel("numberWithUnsignedInt:"), ctypes.c_long(v))
        ctypes.cast(_IMP, _FT_nvv)(arr, _sel("addObject:"), n)
    return arr

def _cfarray_ints(arr) -> List[int]:
    if not arr:
        return []
    count = _cf_count(arr)
    out = []
    for i in range(count):
        item = _cf_at(arr, i)
        if item:
            val = ctypes.cast(_IMP, _FT_lvv)(item, _sel("unsignedLongLongValue"))
            out.append(val)
    return out

# ── Space-Enumeration ──────────────────────────────────────────────────────────

def build_space_map(cid: int) -> Tuple[Dict[int, Tuple[str, int]], int, Dict[str, List[int]]]:
    """Gibt (space_map, active_space_id, display_spaces) zurück."""
    active = _CG.CGSGetActiveSpace(cid)
    dsp_arr = _CG.CGSCopyManagedDisplaySpaces(cid)
    n_disp = _cf_count(dsp_arr)
    space_map: Dict[int, Tuple[str, int]] = {}
    display_spaces: Dict[str, List[int]] = {}

    for di in range(n_disp):
        d = _cf_at(dsp_arr, di)
        disp_id = (
            _dict_str(d, 'Display Identifier') or
            _dict_str(d, 'DisplayIdentifier') or
            f'display_{di}'
        )
        spaces_val = _dict_val(d, 'Spaces') or _dict_val(d, 'spaces')
        if not spaces_val:
            continue
        ids: List[int] = []
        for si in range(_cf_count(spaces_val)):
            sp = _cf_at(spaces_val, si)
            sid = (
                _dict_long(sp, 'ManagedSpaceID') or
                _dict_long(sp, 'id') or
                _dict_long(sp, 'ID')
            )
            if sid is not None:
                space_map[sid] = (disp_id[:12], si + 1)
                ids.append(sid)
        display_spaces[disp_id] = ids

    return space_map, active, display_spaces


def choose_target_space(cid: int, override: Optional[int]) -> Tuple[int, int]:
    """Gibt (active_space, target_space) zurück.

    override: explizite Space-ID. None → auto: erster nicht-aktiver Space auf
    demselben Display (same-Display-Constraint um Cross-Display-Artefakte auszuschließen).
    """
    space_map, active, display_spaces = build_space_map(cid)

    print(f"\n── Space-Übersicht ──────────────────────────────────────────")
    for disp, ids in display_spaces.items():
        for sid in ids:
            marker = " ← aktiv" if sid == active else ""
            no = space_map[sid][1]
            print(f"  space_id={sid:6}  desktop={no}  display={disp[:20]}{marker}")

    if override is not None:
        if override not in space_map:
            sys.exit(f"ERROR: --space {override} nicht in bekannten Spaces {list(space_map.keys())}")
        return active, override

    active_display = next(
        (disp for disp, ids in display_spaces.items() if active in ids), None
    )
    if active_display is None:
        sys.exit(f"ERROR: aktiver Space {active} nicht in CGSCopyManagedDisplaySpaces")

    candidates = [s for s in display_spaces[active_display] if s != active]
    if not candidates:
        sys.exit(
            f"ERROR: kein zweiter Space auf Display '{active_display[:20]}'. "
            "Bitte in Mission Control einen zweiten Desktop anlegen."
        )
    return active, candidates[0]

# ── Fenster-Erkennung ──────────────────────────────────────────────────────────

def wids_for_owner(owner_name: str) -> Set[int]:
    arr = _CG.CGWindowListCopyWindowInfo(0, 0)
    out: Set[int] = set()
    for i in range(_cf_count(arr)):
        d = _cf_at(arr, i)
        if _dict_long(d, "kCGWindowLayer") != 0:
            continue
        if _dict_str(d, "kCGWindowOwnerName") != owner_name:
            continue
        wid = _dict_long(d, "kCGWindowNumber")
        if wid is not None:
            out.add(wid)
    return out


def open_new_textedit_window() -> None:
    """Öffnet genau ein neues TextEdit-Dokument via AppleScript — robust auch wenn
    TextEdit bereits läuft (im Gegensatz zu 'open -a TextEdit' das TextEdit nur
    aktiviert wenn es schon läuft)."""
    subprocess.run(
        ['osascript', '-e', 'tell application "TextEdit" to make new document'],
        check=True,
    )


def wait_for_new_window(owner_name: str, timeout: float = 6.0) -> Optional[int]:
    """before/after-Diff nach open_new_textedit_window. Wird vor dem open-Call
    aufgerufen (snapshotted before), DANN open, DANN poll."""
    before = wids_for_owner(owner_name)
    _dbg(f"before-snapshot: {len(before)} Fenster von {owner_name}")
    return before, lambda: _poll_new(owner_name, before, timeout)


def _poll_new(owner_name: str, before: Set[int], timeout: float) -> Optional[int]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        time.sleep(0.15)
        after = wids_for_owner(owner_name)
        new = after - before
        if new:
            wid = next(iter(new))
            print(f"  Fenster erkannt (before/after-Diff): wid={wid}  "
                  f"(before={len(before)}, after={len(after)})")
            return wid
    return None

# ── Space-Verifikation ─────────────────────────────────────────────────────────

def get_window_space(cid: int, wid: int) -> Optional[int]:
    """Primäre Verifikation: CGSGetWindowWorkspace → direkte per-Fenster Space-ID.

    Gibt None zurück wenn der Call fehlschlägt (z.B. TCC-Einschränkung).
    Kein try/except — Ausnahmen (Segfault etc.) sollen sichtbar sein.
    """
    out = ctypes.c_uint64(0)
    rc = _CG.CGSGetWindowWorkspace(cid, ctypes.c_uint32(wid), ctypes.byref(out))
    _dbg(f"CGSGetWindowWorkspace(cid={cid}, wid={wid}) rc={rc} out={out.value}")
    if rc != 0:
        return None
    return out.value if out.value != 0 else None


def get_window_spaces_copy(cid: int, wid: int) -> List[int]:
    """Sekundäre Verifikation: CGSCopySpacesForWindows (Array-Return).
    Liefert auf macOS 15 für fremde Prozess-Fenster häufig [] (TCC-Einschränkung).
    """
    wid_arr = _make_uint_array([wid])

    result = _SL.SLSCopySpacesForWindows(cid, 7, wid_arr)
    _dbg(f"SLSCopySpacesForWindows ptr={result}")
    if result:
        ids = _cfarray_ints(result)
        _dbg(f"SLS count={_cf_count(result)} ids={ids}")
        if ids:
            return ids

    result2 = _CG.CGSCopySpacesForWindows(cid, 7, wid_arr)
    _dbg(f"CGSCopySpacesForWindows ptr={result2}")
    if result2:
        ids2 = _cfarray_ints(result2)
        _dbg(f"CGS count={_cf_count(result2)} ids={ids2}")
        return ids2
    return []

# ── Move-Funktionen ────────────────────────────────────────────────────────────

def move_cgs(cid: int, wids: List[int], space_id: int) -> int:
    """CGSMoveWindowsToManagedSpace (CoreGraphics) — erwartet No-Op auf macOS 15."""
    rc = _CG.CGSMoveWindowsToManagedSpace(cid, _make_uint_array(wids), ctypes.c_uint64(space_id))
    _dbg(f"CGSMoveWindowsToManagedSpace rc={rc}")
    return rc


def move_sls(cid: int, wids: List[int], space_id: int) -> int:
    """SLSMoveWindowsToManagedSpace (SkyLight) — Stufe 2, primärer Kandidat."""
    rc = _SL.SLSMoveWindowsToManagedSpace(cid, _make_uint_array(wids), ctypes.c_uint64(space_id))
    _dbg(f"SLSMoveWindowsToManagedSpace rc={rc}")
    return rc

# ── Test-Kern ──────────────────────────────────────────────────────────────────

def run_test(label: str, move_fn, cid: int, wid: int, target_space: int) -> bool:
    """Liest before-space, ruft Move auf, liest after-space.

    Kein try/except auf dem Move-Call — TCC/Permission-Fehler sollen unverdeckt erscheinen.
    Gibt True bei PASS zurück.
    """
    print(f"\n── Test {label} ──────────────────────────────────────────────")

    before_ws = get_window_space(cid, wid)
    before_copy = get_window_spaces_copy(cid, wid)
    print(f"  before  CGSGetWindowWorkspace:  space={before_ws}")
    print(f"  before  CGSCopySpacesForWindows: {before_copy}")

    print(f"  → Move-Call (wid={wid}, target={target_space})...")
    rc = move_fn(cid, [wid], target_space)
    print(f"  Return-Code: {rc}")
    time.sleep(0.5)

    after_ws = get_window_space(cid, wid)
    after_copy = get_window_spaces_copy(cid, wid)
    print(f"  after   CGSGetWindowWorkspace:  space={after_ws}")
    print(f"  after   CGSCopySpacesForWindows: {after_copy}")
    print(f"  target-space: {target_space}")

    # Primäre Verifikation: CGSGetWindowWorkspace
    if after_ws is not None and before_ws is not None:
        passed = after_ws == target_space
        src = "CGSGetWindowWorkspace"
    elif after_copy:
        passed = target_space in after_copy
        src = "CGSCopySpacesForWindows"
    else:
        print("  WARN: Beide Verifikations-APIs geben None/[] zurück.")
        print("        Mögliche Ursache: python3 darf Fenster fremder Prozesse")
        print("        auf macOS 15 nicht per SLS/CGS space-querien (TCC).")
        print("        Visuelle Verifikation nötig — Probe-Ergebnis nicht eindeutig.")
        passed = False
        src = "keine"

    print(f"  Verifikation via:  {src}")
    print(f"  Ergebnis:          {'PASS' if passed else 'FAIL'}")
    return passed


def open_test_window(label: str) -> int:
    """Snapshot → open → poll. Gibt wid zurück oder beendet mit Fehler."""
    print(f"\n  Öffne TextEdit-Fenster für Test {label}...")
    _, poll = wait_for_new_window('TextEdit')
    open_new_textedit_window()
    time.sleep(0.3)
    wid = poll()
    if wid is None:
        print(
            "ERROR: Kein neues TextEdit-Fenster nach 6s erkannt.\n"
            "Mögliche Ursache: python3 hat keine Accessibility/Screen-Recording-Berechtigung\n"
            "  → Systemeinstellungen → Datenschutz & Sicherheit → Bildschirmaufnahme\n"
            "     Terminal (oder python3) eintragen, dann neu starten.",
            file=sys.stderr,
        )
        close_all_textedit()
        sys.exit(1)
    return wid


def close_all_textedit():
    subprocess.run(
        ['osascript', '-e', 'tell application "TextEdit" to close every window without saving'],
        capture_output=True,
    )


# ── main ───────────────────────────────────────────────────────────────────────

def main() -> int:
    global _DEBUG
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument('--space', type=int, default=None,
                        help='Ziel-Space-ID (überschreibt Auto-Auswahl)')
    parser.add_argument('--debug', action='store_true', help='Rohe API-Werte ausgeben')
    args = parser.parse_args()
    _DEBUG = args.debug

    print("── Space-Move Probe — macOS 15.7 ────────────────────────────")
    cid = _CG.CGSMainConnectionID()
    sls_cid = _SL.SLSMainConnectionID()
    print(f"CGS connection ID:  {cid}")
    print(f"SLS connection ID:  {sls_cid}")

    active, target = choose_target_space(cid, args.space)
    print(f"\nAktiver Space:  {active}")
    print(f"Ziel-Space:     {target}")

    results: Dict[str, Optional[bool]] = {}

    # Test A: CGSMoveWindowsToManagedSpace (CoreGraphics, legacy)
    wid_a = open_test_window("A")
    results['A: CGSMoveWindowsToManagedSpace (CoreGraphics, legacy)'] = run_test(
        "A: CGSMoveWindowsToManagedSpace (CoreGraphics, legacy)",
        move_cgs, cid, wid_a, target,
    )

    # Test B: SLSMoveWindowsToManagedSpace (SkyLight, Stufe 2)
    wid_b = open_test_window("B")
    results['B: SLSMoveWindowsToManagedSpace (SkyLight, Stufe 2)'] = run_test(
        "B: SLSMoveWindowsToManagedSpace (SkyLight, Stufe 2)",
        move_sls, cid, wid_b, target,
    )

    # Zusammenfassung
    print("\n" + "=" * 60)
    print("ERGEBNIS-ZUSAMMENFASSUNG")
    print(f"  Aktiver Space:  {active}")
    print(f"  Ziel-Space:     {target}")
    print()
    any_pass = False
    for name, passed in results.items():
        if passed is True:
            mark, any_pass = "PASS", True
        elif passed is False:
            mark = "FAIL"
        else:
            mark = "UNCLEAR"
        print(f"  [{mark}]  {name}")
    print("=" * 60)

    close_all_textedit()
    return 0 if any_pass else 1


if __name__ == '__main__':
    sys.exit(main())
