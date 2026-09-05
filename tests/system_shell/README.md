# Debian system-shell workload matrix

This directory contains a host-side runner for comparing real workloads under
Debian's `dash` and Rush. It builds fresh container pairs for Debian bookworm
and trixie, runs each pair sequentially, and retains stage logs, statuses,
runtimes, environment details, image inspection data, and an honest comparison
summary.

## Prerequisites and use

Docker must be installed and accessible to the invoking user. The runner uses
the Docker CLI and respects `DOCKER_HOST`; where required, invoke it with
`sudo env DOCKER_HOST=...` or configure normal Docker access. Containers are not privileged and
the runner never changes the host's `/bin/sh`.

Build Rush first, without registering it as the host shell:

```sh
zig build -Dregister-shell=false
python3 tests/system_shell/run.py --rush zig-out/bin/rush --output system-shell-results
```

Run one suite, or repeat `--suite` to select an explicit matrix:

```sh
python3 tests/system_shell/run.py --rush zig-out/bin/rush \
  --output system-shell-results --suite bookworm --suite trixie
```

With no `--suite`, both bookworm and trixie run. Each workload has a 45-minute
outer timeout. The runner always attempts to copy `/results`, even after a
workload failure, and removes only the uniquely named containers and images it
created. Build failures are recorded while allowing later suites to continue.
The output directory must be empty. The default Docker network is `bridge`;
use `--network host` only where the Docker environment requires it (such as an
orb daemon without a bridge). No ports or services are deliberately exposed.

## Workloads

- Make/shebang, libc system/popen, Python subprocess callers, and interactive
  startup/credential checks.
- Hello, dash, gzip, coreutils, and findutils: configure, build, upstream check,
  and install. GNU tests run as an unprivileged user. Each stage is capped at
  ten minutes; timeout or prerequisite skips are failures, not passes.
  Sources are pristine upstream release archives downloaded from Debian's
  source repositories, not Debian-patched trees. This avoids testing stale
  generated files without the distro's package-build preparation. Source
  archive hashes are recorded alongside installed package versions.
- Git: build, five selected upstream test scripts (basic, init, CRLF,
  parse-options, update-ref), and install. This is not the full Git suite.
  Git's prerequisite lint checks remain enabled; an early failure can prevent
  the selected scripts from running.
- Install, configure, reinstall, remove, and purge cron, logrotate, man-db,
  and openssh-server; reinstall certificates; require a clean final dpkg audit.
- Run `apt-get upgrade` within each release. On an up-to-date image this may
  upgrade nothing; this is not a distribution upgrade. A separate two-version
  fixture package guarantees that dpkg upgrade maintainer-script transitions
  execute, and the runner compares their invocation logs between shells.

The first run downloads and compiles six source packages per release. Allow
substantial disk space and tens of minutes. Upstream skips and warnings remain
in the logs; a zero `make check` status is not a claim that every test ran.
Stage durations use a monotonic clock, but a single run is not a benchmark.

Validate the runner without Docker with:

```sh
python3 -m unittest discover -s tests/system_shell -p 'test_*.py'
bash -n tests/system_shell/workload.bash
```

## Interpreting artifacts

`metadata.json` records the Rush SHA-256 and Git HEAD when available; `fixtures/`
preserves the scripts used. Every suite records the Docker build log and base
and built-image inspection; each
shell directory contains `status.tsv`, `environment.txt`, stage logs, and the
container transcript. `summary.json` is machine-readable and `summary.md` is a
short report. Artifacts and logs remain in the requested output directory.

The run fails for nonzero stage or container status, timeout, missing or
malformed status data, infrastructure failure, unequal stage sets, or a
difference in the selected stdout smoke logs (`make`, `libc-callers`, and
`python-callers`) or maintainer-script invocation logs. Stage logs combine
stdout and stderr. Matching zero exit statuses do **not** imply that all output
matched; inspect the retained logs when investigating baseline differences.
The goal is representative workload evidence, not a green result obtained by
hiding mismatches.
The final `shell-target` stage verifies that package operations did not replace
the candidate `/bin/sh` and serves as a completion check for the runner.

The image references are `debian:bookworm-slim` and `debian:trixie-slim`.
Recorded image IDs snapshot what was resolved for a run, but mutable package
repositories mean this is not full apt-level determinism. Workloads must not
expect service managers or daemons to boot: service startup is blocked in these
containers.
