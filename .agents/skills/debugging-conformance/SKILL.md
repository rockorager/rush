---
name: debugging-conformance
description: "Investigates Rush shell conformance mismatches. Use when comparing Rush POSIX behavior against dash, Bash POSIX mode, and yash POSIX mode, or when fixing conformance failures."
---

# Debugging Conformance

Use this workflow for POSIX conformance failures and behavior differences between
Rush and the primary reference shells.

Before running reduced scripts, build Rush once so all ad hoc comparisons use the
same binary:

```bash
zig build
```

## Reference Shells

For POSIX comparisons, use exactly these targets:

```bash
./zig-out/bin/rush --posix -c 'SCRIPT'
dash -c 'SCRIPT'
bash --posix -c 'SCRIPT'
yash -o posixlycorrect -c 'SCRIPT'
```

For multi-line scripts, write a temporary file and run:

```bash
tmp_script=$(mktemp)
cat >"$tmp_script" <<'SH'
SCRIPT GOES HERE
SH

./zig-out/bin/rush --posix "$tmp_script"
dash "$tmp_script"
bash --posix "$tmp_script"
yash -o posixlycorrect "$tmp_script"

rm -f "$tmp_script"
```

Do not substitute macOS `/bin/sh`, macOS `/bin/bash` 3.2, zsh, BusyBox
ash, ksh, or another shell for the primary comparison set unless the user
explicitly asks for a platform-specific check.

## Default / Bash-Mode Behavior

For non-POSIX Rush behavior, current stable GNU Bash is the primary extension
reference:

```bash
./zig-out/bin/rush -c 'SCRIPT'
bash -c 'SCRIPT'
```

Only broaden the survey when it answers a specific compatibility question:

- Compare against `bash --posix` and `rush --posix` to make sure an extension did
  not leak into POSIX mode.
- Compare against zsh, ksh, or other shells when the feature is commonly shared
  across shell families and Bash is not the whole compatibility story.
- Compare against macOS Bash 3.2 only for legacy macOS migration questions, not
  as the main default-mode oracle.

Rush without `--posix` must still implement POSIX shell behavior. Treat default
mode as POSIX plus extensions, not as a separate dialect: valid POSIX scripts
should keep their POSIX meaning unless a documented, intentional extension
changes behavior.

## Workflow

1. Reduce the failure to the smallest script that still demonstrates the
   mismatch.
2. Run the reduced script against Rush in POSIX mode and all three primary
   reference shells using the commands above.
3. Classify the mismatch:
   - **Spec violation:** POSIX Issue 8 requires one behavior and Rush differs.
   - **Test bug:** the conformance case expects behavior POSIX does not require,
     or the expected stdout/stderr/status is wrong.
   - **Unspecified / undefined / implementation-defined:** POSIX leaves room for
     multiple behaviors; use the reference shell survey and the conformance
     policy to choose Rush behavior.
   - **Extension leak:** behavior is valid in default/Bash mode but must not be
     active under `rush --posix`.
   - **Default-mode extension mismatch:** Rush default mode differs from current
     stable Bash for behavior Rush intends to support as a Bash-compatible
     extension.
   - **Runtime/platform issue:** the mismatch depends on filesystem, locale,
     environment, signal, tty, or process behavior rather than shell semantics.
4. Decide the appropriate fix before editing:
   - Fix Rush when POSIX requires behavior or when the chosen policy says Rush
     should follow the reference shells.
   - Fix or narrow the conformance case when the test encodes non-portable or
     incorrect expectations.
   - Add documentation only for durable, non-obvious compatibility choices that
     future maintainers are likely to question; do not comment every decision in
     unspecified space.
5. Add the smallest useful coverage:
   - Add a conformance case for user-visible shell behavior.
   - Add unit tests for parser, expansion, evaluator, or runtime internals when
     the bug is easiest to isolate at that layer.
   - Prefer both only when the bug crosses an internal boundary and needs a
     user-visible regression case.
6. Implement the fix with the smallest scoped change that follows existing
   shell/runtime ownership boundaries.
7. Rebuild Rush so subsequent script comparisons exercise the updated binary:

```bash
zig build
```

8. Rerun the reduced script against Rush and the three reference shells.
9. Rerun the relevant conformance target, for example:

```bash
zig build conformance -- --mode posix tests/posix/FILE.zon
zig build conformance -- --shell dash --mode posix tests/posix/FILE.zon
zig build conformance -- --shell bash --shell-arg --posix --mode posix tests/posix/FILE.zon
zig build conformance -- --shell yash --mode posix tests/posix/FILE.zon
zig build conformance -- --mode bash tests/bash/FILE.zon
```

Use `--case TEXT` for a focused diff while debugging, then run the containing
file or broader suite before finishing.

## POSIX Research

When checking the specification, prefer POSIX.1-2024 / Issue 8 text from
`pubs.opengroup.org`. Treat older POSIX.1-2017 / Issue 7 material as secondary
unless the code or test explicitly documents an older compatibility choice.
