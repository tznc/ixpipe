"""Runs a Script tool's Python code: unsandboxed, in the user's interpreter.

`inputs` maps each input to rows (a list of dicts) or, with the parquet
format, to its Parquet file. The script sets `output`: a list of dicts, a
dict of columns, or anything with `to_parquet` (a pandas DataFrame).
"""
import contextlib
import io
import json
import linecache
import os
import traceback

SCRIPT = "script.py"
MAX_TEXT = 1_000_000
_MISSING = object()


def run(code, inputs, output_path, fmt):
    out, err = io.StringIO(), io.StringIO()
    result = {"stdout": "", "stderr": "", "error": None, "written": None}
    try:
        env = {
            "__name__": "__main__",
            "inputs": {name: path if fmt == "parquet" else _read(path) for name, path in inputs.items()},
            "output_path": output_path,
        }
        linecache.cache[SCRIPT] = (len(code), None, code.splitlines(True), SCRIPT)
        compiled = compile(code, SCRIPT, "exec")
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            exec(compiled, env)
        result["written"] = _write(env.get("output", _MISSING), output_path, fmt)
    except BaseException as e:  # the script's errors, SystemExit included
        result["error"] = _error(e)
    result["stdout"] = out.getvalue()[:MAX_TEXT]
    result["stderr"] = err.getvalue()[:MAX_TEXT]
    return result


def _read(path):
    with open(path, encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


def _write(output, path, fmt):
    if output is _MISSING:
        if fmt == "parquet" and os.path.exists(path):
            return {"format": "parquet"}
        return {"missing": True}
    if hasattr(output, "to_parquet"):
        output.to_parquet(path, index=False)
        return {"format": "parquet"}
    if isinstance(output, dict):
        columns = [str(k) for k in output]
        values = [list(v) for v in output.values()]
        if len({len(v) for v in values}) > 1:
            return {"bad": "output's columns have different lengths"}
        rows = [dict(zip(columns, row)) for row in zip(*values)]
    elif isinstance(output, list):
        bad = next((r for r in output if not isinstance(r, dict)), None)
        if bad is not None:
            return {"bad": f"output is a list of {type(bad).__name__}, not of dicts"}
        rows = output
        columns = list(dict.fromkeys(str(k) for row in rows for k in row))
    else:
        return {"bad": f"output is a {type(output).__name__}"}
    with open(path, "w", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row, default=str))
            f.write("\n")
    return {"format": "jsonl", "columns": columns, "rows": len(rows)}


def _error(e):
    if isinstance(e, SyntaxError) and e.filename == SCRIPT:
        line, tb = e.lineno, None
    else:
        tb = e.__traceback__
        # Drop this runner's frames: the traceback starts in the script.
        while tb is not None and tb.tb_frame.f_code.co_filename != SCRIPT:
            tb = tb.tb_next
        line = None
        frame = tb
        while frame is not None:
            if frame.tb_frame.f_code.co_filename == SCRIPT:
                line = frame.tb_lineno
            frame = frame.tb_next
    text = "".join(traceback.format_exception(type(e), e, tb))
    return {"type": type(e).__name__, "message": str(e), "line": line, "traceback": text[:MAX_TEXT]}
