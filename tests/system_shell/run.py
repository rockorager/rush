#!/usr/bin/env python3
"""Run the system-shell workload against dash and Rush in Debian containers."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import uuid


SUITES = ("bookworm", "trixie")
SHELLS = ("dash", "rush")
SMOKE_STAGES = ("make", "libc-callers", "python-callers")
WORKLOAD_TIMEOUT = 45 * 60


def run(
    command: list[str],
    *,
    log: Path | None = None,
    timeout: int | None = None,
    cwd: Path | None = None,
) -> subprocess.CompletedProcess[str]:
    started = time.monotonic()
    try:
        result = subprocess.run(
            command,
            cwd=cwd,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as error:
        output = error.stdout or ""
        if isinstance(output, bytes):
            output = output.decode(errors="replace")
        if log:
            log.write_text(output + f"\nrunner: timed out after {timeout} seconds\n")
        raise
    if log:
        log.write_text(result.stdout)
    result.elapsed = time.monotonic() - started  # type: ignore[attr-defined]
    return result


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_statuses(path: Path) -> tuple[dict[str, dict[str, str]], list[str]]:
    statuses: dict[str, dict[str, str]] = {}
    errors: list[str] = []
    if not path.is_file():
        return statuses, ["missing status.tsv"]
    try:
        with path.open(newline="") as source:
            reader = csv.DictReader(source, delimiter="\t")
            if reader.fieldnames != ["stage", "status", "seconds"]:
                errors.append(f"unexpected status.tsv header: {reader.fieldnames!r}")
            for row in reader:
                stage = row.get("stage", "")
                if not stage:
                    errors.append("status.tsv contains a row without a stage")
                elif stage in statuses:
                    errors.append(f"duplicate status row for {stage}")
                else:
                    statuses[stage] = row
    except (OSError, csv.Error) as error:
        errors.append(f"cannot read status.tsv: {error}")
    if not statuses:
        errors.append("status.tsv contains no stages")
    if "shell-target" not in statuses:
        errors.append("workload did not reach its final shell-target check")
    for stage, row in statuses.items():
        try:
            if int(row.get("status", "")) != 0:
                errors.append(f"{stage} exited {row.get('status')}")
        except ValueError:
            errors.append(f"{stage} has non-numeric status {row.get('status')!r}")
    return statuses, errors


def copy_fixture_tree(source: Path, destination: Path, output: Path) -> None:
    output_resolved = output.resolve()

    def ignore(directory: str, names: list[str]) -> set[str]:
        ignored = {"__pycache__"} & set(names)
        for name in names:
            candidate = (Path(directory) / name).resolve()
            if candidate == output_resolved or output_resolved.is_relative_to(candidate):
                ignored.add(name)
        return ignored

    shutil.copytree(source, destination, ignore=ignore)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rush", required=True, type=Path, help="path to the built Rush executable")
    parser.add_argument("--output", required=True, type=Path, help="directory in which to write artifacts")
    parser.add_argument("--suite", action="append", choices=SUITES, help="Debian suite (repeatable; default: both)")
    parser.add_argument("--network", default="bridge", help="Docker network for builds and containers")
    args = parser.parse_args()

    rush = args.rush.resolve()
    if not rush.is_file():
        parser.error(f"Rush binary does not exist: {rush}")
    if shutil.which("docker") is None:
        parser.error("docker CLI was not found in PATH")

    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("output directory must be empty to avoid mixing runs")
    output.mkdir(parents=True, exist_ok=True)
    suites = list(dict.fromkeys(args.suite or SUITES))
    run_id = f"{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}-{os.getpid()}-{uuid.uuid4().hex[:8]}"
    source = Path(__file__).resolve().parent
    summary: dict[str, object] = {"run_id": run_id, "suites": {}, "failures": []}
    failures: list[str] = summary["failures"]  # type: ignore[assignment]

    metadata: dict[str, object] = {
        "run_id": run_id,
        "rush_path": str(rush),
        "rush_sha256": sha256(rush),
        "docker_host_set": "DOCKER_HOST" in os.environ,
    }
    git = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=source, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL
    )
    if git.returncode == 0:
        metadata["git_head"] = git.stdout.strip()
    (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    copy_fixture_tree(source, output / "fixtures", output)

    with tempfile.TemporaryDirectory(prefix="rush-system-shell-") as temporary:
        context = Path(temporary) / "context"
        copy_fixture_tree(source, context / "fixtures", output)
        shutil.copy2(rush, context / "rush")

        for suite in suites:
            suite_dir = output / suite
            suite_dir.mkdir(exist_ok=True)
            image = f"rush-system-shell:{run_id.lower()}-{suite}"
            suite_result: dict[str, object] = {"image": image, "shells": {}, "comparisons": []}
            summary["suites"][suite] = suite_result  # type: ignore[index]
            built = False
            try:
                build = run(
                    [
                        "docker",
                        "build",
                        "--network",
                        args.network,
                        "-f",
                        "fixtures/Dockerfile",
                        "--build-arg",
                        f"DEBIAN_IMAGE=debian:{suite}-slim",
                        "-t",
                        image,
                        ".",
                    ],
                    log=suite_dir / "docker-build.log",
                    timeout=WORKLOAD_TIMEOUT,
                    cwd=context,
                )
                suite_result["build_seconds"] = round(build.elapsed, 3)  # type: ignore[attr-defined]
                suite_result["build_status"] = build.returncode
                if build.returncode != 0:
                    failures.append(f"{suite}: image build failed ({build.returncode})")
                    continue
                built = True
                inspect = run(["docker", "image", "inspect", image])
                (suite_dir / "image-inspect.json").write_text(inspect.stdout)
                if inspect.returncode != 0:
                    failures.append(f"{suite}: could not inspect built image")
                base = run(["docker", "image", "inspect", f"debian:{suite}-slim"])
                (suite_dir / "base-image-inspect.json").write_text(base.stdout)

                all_statuses: dict[str, dict[str, dict[str, str]]] = {}
                for shell in SHELLS:
                    shell_dir = suite_dir / shell
                    shell_dir.mkdir(exist_ok=True)
                    name = f"rush-system-shell-{run_id.lower()}-{suite}-{shell}"
                    shell_result: dict[str, object] = {"container": name}
                    suite_result["shells"][shell] = shell_result  # type: ignore[index]
                    created = False
                    try:
                        create = run([
                            "docker", "create", "--network", args.network, "--name", name, image,
                            "/bin/bash", "/fixtures/workload.bash", shell,
                        ], log=shell_dir / "docker-create.log")
                        if create.returncode != 0:
                            failures.append(f"{suite}/{shell}: container creation failed")
                            continue
                        created = True
                        try:
                            workload = run(
                                ["docker", "start", "-a", name],
                                log=shell_dir / "container.log",
                                timeout=WORKLOAD_TIMEOUT,
                            )
                            shell_result["container_status"] = workload.returncode
                            shell_result["container_seconds"] = round(workload.elapsed, 3)  # type: ignore[attr-defined]
                            if workload.returncode != 0:
                                failures.append(f"{suite}/{shell}: workload container exited {workload.returncode}")
                        except subprocess.TimeoutExpired:
                            shell_result["timed_out"] = True
                            failures.append(f"{suite}/{shell}: workload timed out after {WORKLOAD_TIMEOUT}s")
                            run(["docker", "kill", name], log=shell_dir / "docker-kill.log")
                    finally:
                        if created:
                            copied = run(["docker", "cp", f"{name}:/results/.", str(shell_dir)])
                            if copied.returncode != 0:
                                (shell_dir / "docker-cp.log").write_text(copied.stdout)
                                failures.append(f"{suite}/{shell}: failed to copy /results")
                            removed = run(["docker", "rm", "-f", name])
                            if removed.returncode != 0:
                                failures.append(f"{suite}/{shell}: failed to remove owned container {name}")
                    statuses, status_errors = read_statuses(shell_dir / "status.tsv")
                    all_statuses[shell] = statuses
                    shell_result["stages"] = statuses
                    for error in status_errors:
                        failures.append(f"{suite}/{shell}: {error}")

                dash_stages = set(all_statuses.get("dash", {}))
                rush_stages = set(all_statuses.get("rush", {}))
                if dash_stages != rush_stages:
                    message = f"stage sets differ: dash-only={sorted(dash_stages-rush_stages)}, rush-only={sorted(rush_stages-dash_stages)}"
                    suite_result["comparisons"].append(message)  # type: ignore[union-attr]
                    failures.append(f"{suite}: {message}")
                for stage in SMOKE_STAGES:
                    dash_log = suite_dir / "dash" / f"{stage}.log"
                    rush_log = suite_dir / "rush" / f"{stage}.log"
                    if not dash_log.is_file() or not rush_log.is_file():
                        message = f"{stage}: smoke log missing for one or both shells"
                        failures.append(f"{suite}: {message}")
                    elif dash_log.read_bytes() == rush_log.read_bytes():
                        message = f"{stage}: logs byte-identical"
                    else:
                        message = f"{stage}: logs differ (see per-shell artifacts)"
                        failures.append(f"{suite}: {stage} output differs")
                    suite_result["comparisons"].append(message)  # type: ignore[union-attr]
                dash_lifecycle = suite_dir / "dash" / "lifecycle.log"
                rush_lifecycle = suite_dir / "rush" / "lifecycle.log"
                if (not dash_lifecycle.is_file() or not rush_lifecycle.is_file() or
                        dash_lifecycle.read_bytes() != rush_lifecycle.read_bytes()):
                    failures.append(f"{suite}: maintainer-script lifecycle logs missing or different")
            except (OSError, subprocess.TimeoutExpired) as error:
                failures.append(f"{suite}: infrastructure failure: {error}")
            finally:
                if built:
                    removal = run(["docker", "image", "rm", "-f", image], log=suite_dir / "docker-image-rm.log")
                    if removal.returncode != 0:
                        failures.append(f"{suite}: failed to remove owned image {image}")

    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    lines = [f"# System shell run {run_id}", "", f"Result: **{'FAIL' if failures else 'PASS'}**", ""]
    lines += ["| Suite | Stage | dash status / seconds | Rush status / seconds |", "|---|---|---|---|"]
    for suite, data in summary["suites"].items():
        shells = data["shells"]
        dash = shells.get("dash", {}).get("stages", {})
        rush = shells.get("rush", {}).get("stages", {})
        for stage in dict.fromkeys([*dash, *rush]):
            cells = []
            for stages in (dash, rush):
                row = stages.get(stage)
                cells.append(f"{row['status']} / {row['seconds']}" if row else "missing")
            lines.append(f"| {suite} | {stage} | {' | '.join(cells)} |")
    lines.append("")
    lines.extend(f"- {failure}" for failure in failures)
    if not failures:
        lines.append("All recorded stages exited zero and selected smoke logs matched; this does not assert all workload output is equal.")
    (output / "summary.md").write_text("\n".join(lines) + "\n")
    print(f"artifacts: {output}")
    print(f"result: {'FAIL' if failures else 'PASS'} ({len(failures)} failure(s))")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
