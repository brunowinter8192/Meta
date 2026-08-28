# spawn.py model-resolution verification — 2026-08-28T20:35:35

Missing config file -> 'claude-sonnet-5' (expected hardcoded fallback)
Valid config -> 'claude-fable-5' (expected config's worker model)
Malformed JSON -> 'claude-sonnet-5' (expected hardcoded fallback, no raise)
Config missing 'worker' key -> 'claude-sonnet-5' (expected hardcoded fallback)

## argparse resolution (real parser, default=None)
Explicit CLI arg given -> resolved_model='claude-explicit-cli-arg' (expected explicit arg, config never consulted)
CLI arg omitted -> args.model=None (expected None, not the string 'None')
CLI arg omitted -> resolved_model='claude-fable-5' (expected config's worker model, never the literal 'None')

RESULT: PASS — _resolve_worker_model correct for valid/missing/malformed/missing-key config; args.model is real None (never the string 'None') when omitted; the resolved model passed onward is always a concrete non-empty string.
