#!/usr/bin/env python3
"""Small, reproducible Rush comparison benchmark (standard library only)."""

import argparse
import hashlib
import json
import os
import platform
import random
import shutil
import statistics
import subprocess
import time
from pathlib import Path

LOOPS = 50_000
PROCESSES = 200
ARGS64 = " ".join(f"arg{i}" for i in range(64))
CASES = {
    "startup": (":", b"", 25),
    "arithmetic": (
        f'i=0; while [ "$i" -lt {LOOPS} ]; do i=$((i+1)); done; printf "%s\\n" "$i"',
        f"{LOOPS}\n".encode(),
        1,
    ),
    "function-read-one": (
        f'f() {{ : "$1"; }}; i=0; while [ "$i" -lt {LOOPS} ]; do f hello; i=$((i+1)); done; printf "%s\\n" "$i"',
        f"{LOOPS}\n".encode(),
        1,
    ),
    "parameter-trimming": (
        f'x=prefix_middle_suffix; i=0; while [ "$i" -lt {LOOPS} ]; do y=${{x#prefix_}}; z=${{y%_suffix}}; i=$((i+1)); done; printf "%s\\n" "$z"',
        b"middle\n",
        1,
    ),
    "external-true": (
        f'i=0; while [ "$i" -lt {PROCESSES} ]; do /usr/bin/true; i=$((i+1)); done; printf "%s\\n" "$i"',
        f"{PROCESSES}\n".encode(),
        1,
    ),
    "command-substitution": (
        f'i=0; while [ "$i" -lt {PROCESSES} ]; do x=$(printf hello); i=$((i+1)); done; printf "%s\\n" "$x"',
        b"hello\n",
        1,
    ),
    "pipeline": (
        f'i=0; while [ "$i" -lt {PROCESSES} ]; do printf hello | /usr/bin/cat >/dev/null; i=$((i+1)); done; printf "%s\\n" "$i"',
        f"{PROCESSES}\n".encode(),
        1,
    ),
    "inline-eight": (
        f'i=0; while [ "$i" -lt {LOOPS} ]; do : a b c d e f g h; i=$((i+1)); done; printf "%s\\n" "$i"',
        f"{LOOPS}\n".encode(),
        1,
    ),
    "caller-64": (
        f'set -- {ARGS64}; f() {{ : "$1"; }}; i=0; while [ "$i" -lt {LOOPS} ]; do f hello; i=$((i+1)); done; printf "%s\\n" "$i"',
        f"{LOOPS}\n".encode(),
        1,
    ),
}
ENV = {"PATH": "/usr/bin:/bin", "HOME": "/nonexistent", "LC_ALL": "C"}
TIMEOUT = 30


def run(command, script):
    try:
        return subprocess.run(
            command + ["-c", script],
            env=ENV,
            capture_output=True,
            timeout=TIMEOUT,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise SystemExit(f"error: cannot run {command[0]}: {error}") from error


def identity(command):
    if Path(command[0]).name == "dash":
        package_query = shutil.which("dpkg-query", path=ENV["PATH"])
        if package_query:
            result = subprocess.run(
                [package_query, "-W", "-f=${Version}", "dash"],
                env=ENV,
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
            if result.returncode == 0:
                return "dash " + result.stdout.strip()
        return "dash (version unavailable; see executable hash)"
    try:
        result = subprocess.run(
            command + ["--version"],
            env=ENV,
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        line = (result.stdout or result.stderr).splitlines()
        return line[0] if line else str(command[0])
    except (OSError, subprocess.TimeoutExpired):
        return str(command[0])


def git_info():
    def git(*args):
        return subprocess.run(
            ["git", *args], capture_output=True, text=True, timeout=5, check=False
        )

    revision = git("rev-parse", "HEAD")
    dirty = git("status", "--porcelain")
    return {
        "revision": revision.stdout.strip() if revision.returncode == 0 else None,
        "dirty": bool(dirty.stdout) if dirty.returncode == 0 else None,
    }


def parse_args():
    parser = argparse.ArgumentParser(
        description="Benchmark Rush against an installed POSIX shell"
    )
    parser.add_argument(
        "--rush", required=True, help="Rush executable (normally supplied by zig build)"
    )
    parser.add_argument(
        "--optimize", required=True, help="recorded Zig optimization mode"
    )
    parser.add_argument("--lto", required=True, help="recorded Zig LTO mode")
    parser.add_argument(
        "--reference",
        choices=("dash", "bash"),
        default="dash",
        help="installed reference shell (bash is run with --posix)",
    )
    parser.add_argument("--case", action="append", dest="cases", metavar="NAME")
    parser.add_argument("--rounds", type=int, default=9)
    parser.add_argument("--warmups", type=int, default=2)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--cpu", type=int)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.rounds < 1 or args.warmups < 0:
        parser.error("--rounds must be positive and --warmups non-negative")
    unknown = set(args.cases or ()) - CASES.keys()
    if unknown:
        parser.error(
            "unknown --case: "
            + ", ".join(sorted(unknown))
            + "; choices: "
            + ", ".join(CASES)
        )
    return args


def main():
    args = parse_args()
    if args.cpu is not None:
        if not hasattr(os, "sched_setaffinity"):
            raise SystemExit(
                "error: --cpu is supported only where sched_setaffinity is available (normally Linux)"
            )
        try:
            os.sched_setaffinity(0, {args.cpu})
        except (OSError, ValueError) as error:
            raise SystemExit(f"error: cannot set affinity to CPU {args.cpu}: {error}")

    reference_path = shutil.which(args.reference, path=ENV["PATH"])
    if reference_path is None:
        raise SystemExit(
            f"error: reference shell '{args.reference}' is not installed in {ENV['PATH']}"
        )
    rush_path = str(Path(args.rush).resolve())
    shells = {
        "rush": [rush_path, "--posix"],
        args.reference: [reference_path]
        + (["--posix"] if args.reference == "bash" else []),
    }
    selected = list(dict.fromkeys(args.cases or CASES))

    for name in selected:
        script, expected, _ = CASES[name]
        for shell_name, command in shells.items():
            result = run(command, script)
            if (
                result.returncode != 0
                or result.stdout != expected
                or result.stderr != b""
            ):
                raise SystemExit(
                    f"error: correctness check failed: {shell_name}/{name}: "
                    f"status={result.returncode} stdout={result.stdout!r} stderr={result.stderr!r}"
                )

    samples = {name: {shell: [] for shell in shells} for name in selected}
    rng = random.Random(args.seed)
    jobs = [(name, shell) for name in selected for shell in shells]
    for round_index in range(args.warmups + args.rounds):
        rng.shuffle(jobs)
        for name, shell in jobs:
            script, _, batch = CASES[name]
            start = time.perf_counter_ns()
            for _ in range(batch):
                result = run(shells[shell], script)
                if result.returncode != 0:
                    raise SystemExit(
                        f"error: timed command failed: {shell}/{name}: status={result.returncode}"
                    )
            elapsed_ms = (time.perf_counter_ns() - start) / 1_000_000 / batch
            if round_index >= args.warmups:
                samples[name][shell].append(elapsed_ms)

    rush_bytes = Path(rush_path).read_bytes()
    affinity = (
        sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else None
    )
    output = {
        "schema_version": 1,
        "build": {
            "optimize": args.optimize,
            "lto": args.lto,
            "rush_sha256": hashlib.sha256(rush_bytes).hexdigest(),
        },
        "git": git_info(),
        "platform": platform.platform(),
        "affinity": affinity,
        "environment": ENV,
        "timeout_seconds": TIMEOUT,
        "timing": "perf_counter_ns wall time per invocation; captured output; randomized interleaved rounds",
        "seed": args.seed,
        "rounds": args.rounds,
        "warmups": args.warmups,
        "shells": {
            name: {
                "command": command,
                "identity": identity(command),
                "sha256": hashlib.sha256(Path(command[0]).read_bytes()).hexdigest(),
            }
            for name, command in shells.items()
        },
        "cases": {
            name: {
                "script": CASES[name][0],
                "batch": CASES[name][2],
                "expected_stdout": CASES[name][1].decode(),
                "expected_stderr": "",
                "expected_status": 0,
                "results": {
                    shell: {
                        "samples_ms": values,
                        "median_ms": statistics.median(values),
                    }
                    for shell, values in samples[name].items()
                },
            }
            for name in selected
        },
    }
    for name, case in output["cases"].items():
        rush = case["results"]["rush"]["median_ms"]
        ref = case["results"][args.reference]["median_ms"]
        print(
            f"{name:22} rush {rush:9.3f} ms  {args.reference} {ref:9.3f} ms  rush/ref {rush / ref:6.2f}x"
        )
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
