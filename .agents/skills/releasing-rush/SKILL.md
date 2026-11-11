---
name: releasing-rush
description: Releases Rush with `just release`, which tags origin/main as the next semantic version so CI builds, publishes, and updates the AUR package. Use when cutting a release, choosing a patch, minor, or major bump, writing optional release notes, or checking a release's CI.
---

# Releasing Rush

Release tags are the versions. A release is a `vX.Y.Z` tag on a commit of
`main`; release often, whenever `main` has changes worth installing.

## How a release works

- `just release BUMP` releases `origin/main` as the newest tag bumped by
  `patch` (the default), `minor`, or `major`; `just release X.Y.Z` names the
  version, which must be newer than every tag. It refuses when `origin/main`
  is already released or its CI run did not succeed, and lists the commits
  since the last tag before it pushes.
- It commits `release: X.Y.Z` on top of `origin/main`, setting `.version` in
  `build.zig.zon` for builds from a source archive, tags that commit
  `vX.Y.Z`, and pushes the commit and tag atomically. It leaves the local
  checkout and branch untouched. If `main` moved since its fetch, nothing is
  pushed; run it again.
- `.github/workflows/release.yml` runs on the tag. It checks the tag against
  `build.zig.zon`, builds static `rush-X.Y.Z-{x86_64,aarch64}-linux.tar.xz`
  tarballs laid out for a `/usr` prefix and
  `rush-X.Y.Z-{x86_64,aarch64}-macos.tar.xz` tarballs laid out for
  `/usr/local`, runs the aarch64 macOS binary on a macOS runner, publishes
  the tarballs with `SHA256SUMS`, and then publishes `aur/rush-shell-bin` to
  the AUR with that version and the Linux checksums. The AUR step needs the
  `AUR_SSH_PRIVATE_KEY` repository secret.
- The release description is `docs/releases/X.Y.Z.md` when it exists;
  otherwise it lists the commit subjects since the previous release.
- Builds of other commits derive their version from Git: an exact clean tag
  reports `X.Y.Z`, later commits `X.Y.(Z+1)-dev.<distance>+g<sha>`, and dirty
  worktrees append `.dirty`. No version needs bumping after a release.

## Choosing the bump

Versions follow semver strictly from the start: 0.x has no exemption, so what
breaks bumps the major even now. The bump is the highest any commit since the
last tag needs:

- `major`: what makes a user, script, or embedder change something or lose
  something. A builtin, option, syntax, or `rush` argument removed or doing
  something else in a way a working script or configuration would notice;
  startup files, configuration paths, events, or function autoload paths
  moved or reshaped; a history database a new build cannot read; a function,
  type, or behavior removed or changed in `include/rush.h` or `librush`'s
  ABI; a platform or architecture dropped, or a higher floor for the systems
  Rush runs on.
- `minor`: something new, with nothing old breaking. A builtin, option,
  syntax, event, completion, configuration hook, platform, or `rush.h`
  function added; a history format the old data still migrates into.
- `patch`: fixes alone, adding no behavior. This includes making `--posix`
  match POSIX.1-2024 where Rush deviated: scripts may not rely on a
  conformance bug. The exception is a fix that changes what common scripts
  depend on, especially where dash or Bash behaved as Rush did; that is
  `major`. Changes to Rush's own non-POSIX mode are not conformance fixes.

Choose from the commits `git log "$(git describe --tags --abbrev=0 --match
'v[0-9]*' origin/main)..origin/main"` lists, read for what changed for users,
scripts, and embedders rather than from their subjects, and say which bump you
chose and why. When it is between two, take the higher. Never bump
`build.zig.zon` by hand.

## Steps

1. Choose the bump as above.
2. Check that `origin/main` holds what should ship and that its CI passed:
   `gh run list --workflow ci.yml --commit "$(git rev-parse origin/main)"`.
3. For a release that deserves notes, write `docs/releases/X.Y.Z.md` and land
   it on `main` first. Notes stand alone, lead with user-visible impact, call
   out breaking changes and migrations, and contain no forge-specific links.
4. Run `just release BUMP` or `just release X.Y.Z`, and check the commits it
   lists against the bump.
5. Watch the Release workflow through completion with `gh run watch`. Confirm
   the release page lists all four tarballs and `SHA256SUMS`, and that the AUR
   job pushed `rush-shell-bin` X.Y.Z.

## Safety rules

- `just release` pushes to `main` and pushes a tag. Run it only with explicit
  approval for that release.
- Never move, replace, or delete a published tag without explicit approval and
  a clear explanation of the consequences. If the Release workflow fails,
  report the failure and fix forward with the next patch release.
- Do not edit published release notes except to correct a material factual
  error with an explicitly reviewed follow-up.
