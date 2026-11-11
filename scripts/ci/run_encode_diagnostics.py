#!/usr/bin/env python3
"""Windows process-evidence diagnostic runner for lua-simdjson issue117."""

import argparse
import json
import os
import subprocess
import sys
import hashlib
import datetime
import platform
import time
import re
import signal
import tempfile
from pathlib import Path


# Default 8 cases from Task 2
DEFAULT_CASES = [
    "nan",
    "negative-nan",
    "positive-infinity",
    "negative-infinity",
    "array-nan",
    "object-nan",
    "infinite-key",
    "repeat-nan"
]

# Max 1 MiB per output file
MAX_OUTPUT_BYTES = 1024 * 1024


def compute_file_hash(path):
    """Compute SHA-256 hash of a file."""
    sha256_hash = hashlib.sha256()
    try:
        with open(path, "rb") as f:
            for byte_block in iter(lambda: f.read(4096), b""):
                sha256_hash.update(byte_block)
        return sha256_hash.hexdigest()
    except (FileNotFoundError, IOError):
        return None


def compute_dir_files_hash(dir_path, pattern="*.{h,cpp}"):
    """Compute hash of all matching files in directory (for manifest)."""
    dir_path = Path(dir_path)
    if not dir_path.exists():
        return None
    
    sha256_hash = hashlib.sha256()
    try:
        # Get all .h and .cpp files
        files = sorted(dir_path.glob("*.h")) + sorted(dir_path.glob("*.cpp"))
        for fpath in files:
            if fpath.is_file():
                with open(fpath, "rb") as f:
                    sha256_hash.update(f.read())
        return sha256_hash.hexdigest() if files else None
    except Exception:
        return None


def get_platform_module_name():
    """Return platform-specific module name: simdjson.dll or simdjson.so."""
    if platform.system() == "Windows":
        return "simdjson.dll"
    else:
        return "simdjson.so"


def parse_version_from_source(module_dir):
    """Parse version string from source files using regex."""
    module_dir = Path(module_dir)
    
    # Priority 1: Check src/simdjson.h for #define SIMDJSON_VERSION
    src_dir = module_dir / "src"
    if src_dir.exists():
        header_file = src_dir / "simdjson.h"
        if header_file.exists():
            try:
                content = header_file.read_text()
                match = re.search(r'^\s*#define\s+SIMDJSON_VERSION\s+"([^"]+)"', content, re.MULTILINE)
                if match:
                    return match.group(1)
            except Exception:
                pass
    
    # Priority 2: Search *.cpp files in src directory
    if src_dir.exists():
        patterns = [
            r'VERSION\s*=\s*["\']([^"\']+)["\']',
            r'__version__\s*=\s*["\']([^"\']+)["\']',
            r'version\s*:\s*["\']([^"\']+)["\']',
        ]
        for cpp_file in src_dir.glob("*.cpp"):
            try:
                content = cpp_file.read_text()
                for pattern in patterns:
                    match = re.search(pattern, content)
                    if match:
                        return match.group(1)
            except Exception:
                pass
    
    # Priority 3: Search *.cpp files in module_dir root
    for cpp_file in module_dir.glob("*.cpp"):
        try:
            content = cpp_file.read_text()
            for pattern in patterns:
                match = re.search(pattern, content)
                if match:
                    return match.group(1)
        except Exception:
            pass
    
    return None


def read_bounded_file(file_path, max_bytes=MAX_OUTPUT_BYTES):
    """Read file bounded to max_bytes, return (content, was_truncated)."""
    try:
        with open(file_path, "rb") as f:
            data = f.read(max_bytes + 1)
        if len(data) > max_bytes:
            return data[:max_bytes].decode('utf-8', errors='replace'), True
        return data.decode('utf-8', errors='replace'), False
    except Exception as e:
        return f"[Error reading file: {e}]", False


def run_probe_case_with_files(lua_exe, probe_script, case, module_dir, output_dir, timeout_seconds):
    """
    Run a single probe case using file redirection for bounded memory.
    
    Returns: dict with keys:
      - pass: bool, True if PASS <case> was detected in stdout
      - exit_code: int (in hex if written to file)
      - stdout: str (bounded to 1MiB)
      - stderr: str (bounded to 1MiB)
      - duration: float
      - timeout: bool
      - timestamp: ISO string
      - truncated: bool (if output was truncated)
    """
    start_time = time.time()
    start_iso = datetime.datetime.fromtimestamp(start_time, tz=datetime.timezone.utc).isoformat()
    
    # Create temp files for stdout/stderr
    stdout_file = output_dir / f"case_{case}_stdout.txt"
    stderr_file = output_dir / f"case_{case}_stderr.txt"
    
    # Command: [lua, probe_script, case, module_dir]
    cmd = [str(lua_exe), str(probe_script), str(case), str(module_dir)]
    
    result = {
        "pass": False,
        "exit_code": -1,
        "stdout": "",
        "stderr": "",
        "duration": 0.0,
        "timeout": False,
        "timestamp": start_iso,
        "truncated": False,
        "exit_code_hex": "",
        "command": cmd,
    }
    
    proc = None
    try:
        with open(stdout_file, "w") as out_f, open(stderr_file, "w") as err_f:
            if platform.system() == "Windows":
                # Windows: use creationflags to create process group
                proc = subprocess.Popen(
                    cmd,
                    stdout=out_f,
                    stderr=err_f,
                    text=True,
                    creationflags=subprocess.CREATE_NEW_PROCESS_GROUP if platform.system() == "Windows" else 0
                )
            else:
                # POSIX: use start_new_session for process group
                proc = subprocess.Popen(
                    cmd,
                    stdout=out_f,
                    stderr=err_f,
                    text=True,
                    start_new_session=True
                )
        
        # Wait with timeout
        try:
            returncode = proc.wait(timeout=timeout_seconds)
            result["exit_code"] = returncode
        except subprocess.TimeoutExpired:
            result["timeout"] = True
            result["exit_code"] = -124
            
            # Terminate process group
            try:
                if platform.system() == "Windows":
                    subprocess.call(["taskkill", "/T", "/F", "/PID", str(proc.pid)])
                else:
                    os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except Exception:
                pass
            
            proc.wait()  # Ensure process is reaped
        
    except Exception as e:
        result["exit_code"] = -1
        result["stderr"] = str(e)
    
    end_time = time.time()
    end_iso = datetime.datetime.fromtimestamp(end_time, tz=datetime.timezone.utc).isoformat()
    result["duration"] = end_time - start_time
    result["end_timestamp"] = end_iso
    
    # Read bounded output files
    stdout_content, stdout_truncated = read_bounded_file(stdout_file, MAX_OUTPUT_BYTES)
    stderr_content, stderr_truncated = read_bounded_file(stderr_file, MAX_OUTPUT_BYTES)
    
    result["stdout"] = stdout_content
    result["stderr"] = stderr_content
    result["truncated"] = stdout_truncated or stderr_truncated
    result["exit_code_hex"] = f"0x{result['exit_code']:x}"
    
    # Detect PASS marker in stdout
    for line in stdout_content.split('\n'):
        if line.strip() == f"PASS {case}":
            result["pass"] = True
            break
    
    # Fail if output truncated or timeout, even if PASS marker present
    if result["truncated"] or result["timeout"]:
        result["pass"] = False
    
    return result


def run_diagnostics():
    """Main entry point for diagnostic runner."""
    parser = argparse.ArgumentParser(
        description="Process-evidence pipeline for lua-simdjson diagnostics"
    )
    parser.add_argument("--lua", required=True, help="Path to Lua interpreter")
    parser.add_argument("--probe", default=None, help="Path to probe script (optional)")
    parser.add_argument("--module-dir", required=True, help="Directory containing compiled module")
    parser.add_argument("--output", required=True, help="Output directory for results")
    parser.add_argument("--timeout-seconds", type=int, default=60, help="Timeout in seconds")
    parser.add_argument("--case", choices=DEFAULT_CASES, default=None, help="Specific case to run (optional)")

    args = parser.parse_args()

    # Resolve all paths
    lua_exe = Path(args.lua).resolve()
    if not lua_exe.exists():
        print(f"ERROR: Lua interpreter not found at {lua_exe}", file=sys.stderr)
        return 1

    # Default probe path if not provided
    if args.probe is None:
        args.probe = str(Path(__file__).with_name('encode_probe.lua').resolve())
    
    probe_script = Path(args.probe).resolve()
    if not probe_script.exists():
        print(f"ERROR: Probe script not found at {probe_script}", file=sys.stderr)
        return 1

    module_dir = Path(args.module_dir).resolve()
    if not module_dir.is_dir():
        print(f"ERROR: Module directory not found at {module_dir}", file=sys.stderr)
        return 1

    # Check for module file
    module_name = get_platform_module_name()
    module_file = module_dir / module_name
    if not module_file.exists():
        print(f"ERROR: Module file not found at {module_file}", file=sys.stderr)
        return 1

    output_dir = Path(args.output).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    # Determine which cases to run
    cases_to_run = [args.case] if args.case else DEFAULT_CASES

    # Get environment variables
    env_vars = {
        "ISSUE117_HEAD_SHA": os.environ.get("ISSUE117_HEAD_SHA", ""),
        "MERGE_SHA": os.environ.get("ISSUE117_MERGE_SHA", ""),
        "BASE_SHA": os.environ.get("ISSUE117_BASE_SHA", ""),
    }

    # Create manifest
    src_dir = module_dir / "src"
    
    # Build explicit source_sha256 dict
    source_sha256 = {}
    if src_dir.exists():
        for src_file in sorted(src_dir.glob("*.h")) + sorted(src_dir.glob("*.cpp")):
            if src_file.is_file():
                file_hash = compute_file_hash(str(src_file))
                if file_hash:
                    source_sha256[src_file.name] = file_hash
    
    manifest = {
        "timestamp": datetime.datetime.fromtimestamp(time.time(), tz=datetime.timezone.utc).isoformat(),
        "lua_path": str(lua_exe),
        "probe_path": str(probe_script),
        "module_dir": str(module_dir),
        "module_name": module_name,
        "module_sha256": compute_file_hash(module_file),
        "source_sha256": source_sha256 if source_sha256 else None,
        "version": parse_version_from_source(module_dir),
        "environment": env_vars,
        "cases": cases_to_run,
    }

    manifest_file = output_dir / "manifest.json"
    with open(manifest_file, "w") as f:
        json.dump(manifest, f, indent=2)

    # Run all cases
    results = {
        "timestamp": datetime.datetime.fromtimestamp(time.time(), tz=datetime.timezone.utc).isoformat(),
        "cases": {},
    }

    all_passed = True
    for case in cases_to_run:
        case_result = run_probe_case_with_files(lua_exe, probe_script, case, module_dir, output_dir, args.timeout_seconds)
        results["cases"][case] = case_result
        # Success requires BOTH PASS marker AND exit code 0
        case_result["pass"] = case_result["pass"] and case_result["exit_code"] == 0
        if not case_result["pass"]:
            all_passed = False

    # Write results
    results_file = output_dir / "results.json"
    with open(results_file, "w") as f:
        json.dump(results, f, indent=2)

    # Exit 0 only if all cases passed
    return 0 if all_passed else 1


if __name__ == "__main__":
    sys.exit(run_diagnostics())
