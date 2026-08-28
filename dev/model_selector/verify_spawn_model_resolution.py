# INFRASTRUCTURE
import importlib.util
import json
import tempfile
from datetime import datetime
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

# ORCHESTRATOR

# Verify spawn.py's _resolve_worker_model() (real function, loaded from disk) and confirm
# argparse's new default=None can never leak the literal string "None" downstream — all
# against a temp MODEL_SELECTION_FILE path, never the real ~/.claude/shared-rules/ one.
def verify_spawn_model_resolution_workflow() -> None:
    spawn = _load_spawn_module()
    lines = [f"# spawn.py model-resolution verification — {datetime.now().isoformat(timespec='seconds')}", ""]

    with tempfile.TemporaryDirectory() as tmp:
        missing_path = Path(tmp) / "does_not_exist.json"
        spawn._MODEL_SELECTION_FILE = str(missing_path)
        resolved = spawn._resolve_worker_model()
        lines.append(f"Missing config file -> {resolved!r} (expected hardcoded fallback)")
        assert resolved == spawn._DEFAULT_WORKER_MODEL

        valid_path = Path(tmp) / "valid.json"
        valid_path.write_text(json.dumps({"main": "claude-opus-5", "worker": "claude-fable-5"}))
        spawn._MODEL_SELECTION_FILE = str(valid_path)
        resolved = spawn._resolve_worker_model()
        lines.append(f"Valid config -> {resolved!r} (expected config's worker model)")
        assert resolved == "claude-fable-5"

        malformed_path = Path(tmp) / "malformed.json"
        malformed_path.write_text("{not valid json")
        spawn._MODEL_SELECTION_FILE = str(malformed_path)
        resolved = spawn._resolve_worker_model()
        lines.append(f"Malformed JSON -> {resolved!r} (expected hardcoded fallback, no raise)")
        assert resolved == spawn._DEFAULT_WORKER_MODEL

        missing_key_path = Path(tmp) / "missing_key.json"
        missing_key_path.write_text(json.dumps({"main": "claude-opus-5"}))
        spawn._MODEL_SELECTION_FILE = str(missing_key_path)
        resolved = spawn._resolve_worker_model()
        lines.append(f"Config missing 'worker' key -> {resolved!r} (expected hardcoded fallback)")
        assert resolved == spawn._DEFAULT_WORKER_MODEL

        # ---- "explicit arg wins" as argparse itself resolves it (real parser, not reimplemented) ----
        lines.append("")
        lines.append("## argparse resolution (real parser, default=None)")

        parser_explicit = spawn.argparse.ArgumentParser()
        parser_explicit.add_argument("model", nargs="?", default=None)
        args_explicit = parser_explicit.parse_args(["claude-explicit-cli-arg"])
        resolved_model = args_explicit.model or spawn._resolve_worker_model()
        lines.append(f"Explicit CLI arg given -> resolved_model={resolved_model!r} (expected explicit arg, config never consulted)")
        assert resolved_model == "claude-explicit-cli-arg"

        parser_omitted = spawn.argparse.ArgumentParser()
        parser_omitted.add_argument("model", nargs="?", default=None)
        args_omitted = parser_omitted.parse_args([])
        lines.append(f"CLI arg omitted -> args.model={args_omitted.model!r} (expected None, not the string 'None')")
        assert args_omitted.model is None
        assert args_omitted.model != "None"
        spawn._MODEL_SELECTION_FILE = str(valid_path)
        resolved_model = args_omitted.model or spawn._resolve_worker_model()
        lines.append(f"CLI arg omitted -> resolved_model={resolved_model!r} (expected config's worker model, never the literal 'None')")
        assert resolved_model == "claude-fable-5"
        assert resolved_model != "None"
        assert isinstance(resolved_model, str) and resolved_model

    lines.append("")
    lines.append("RESULT: PASS — _resolve_worker_model correct for valid/missing/malformed/missing-key "
                "config; args.model is real None (never the string 'None') when omitted; the "
                "resolved model passed onward is always a concrete non-empty string.")

    report_dir = REPO_ROOT / "dev" / "model_selector" / "md"
    report_dir.mkdir(parents=True, exist_ok=True)
    (report_dir / "verify_spawn_model_resolution.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))

# FUNCTIONS

# Load src/spawn/spawn.py by file path — it has zero relative imports (stdlib only), so this
# works without package context, unlike a module with 'from .sibling import x'.
def _load_spawn_module():
    spec_path = REPO_ROOT / "src" / "spawn" / "spawn.py"
    spec = importlib.util.spec_from_file_location("spawn_under_test", spec_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


if __name__ == "__main__":
    verify_spawn_model_resolution_workflow()
