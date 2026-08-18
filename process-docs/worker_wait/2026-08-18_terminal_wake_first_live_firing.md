# Terminal-Status Wake — First Live Firing, Same Day as the Build

The terminal-status wake (`worker terminal` exit, built and merged earlier this same day after
two wait-hangs on dead workers) fired live for the first time roughly two hours after going
live, on a third worker death in the observing project (monitor-cc).

## The firing, from the live trace

A worker hit its context limit mid-milestone. `wait_trace.log` (pid 62457):

```
event=poll worker=pane-search2 status=limit_reached bg=- class=terminal
event=poll worker=wait-unknown status=idle bg=no class=idle
event=decision all_nonblocking=1 any_terminal=1 stable_count=3 elapsed=1071
event=exit reason=worker_terminal elapsed=1071
```

The wait exited after ~18 minutes total (the death occurred mid-wait; classification + the
3-sample stability window resolved it immediately once the status turned terminal) instead of
grinding to the 3300s ceiling — the orchestrator was woken, captured the dead worker's pane,
verified and salvaged its uncommitted work, and continued the same evening. The mixed case the
suite's Test 9 models (one terminal + one idle worker) is exactly what the trace shows here:
the fold-in produced `worker terminal`, not `workers idle`.

## Standing observations as of 2026-08-18

- The per-poll trace (built the same morning) was what made every one of the day's three
  wait-incidents diagnosable in one `tail` — no forensics.
- Both terminal vocabulary strings appeared in real incidents within one day: `unknown`
  (process fully gone) and `limit_reached` (pane alive with the context banner). The whitelist
  covering both was the right call.
