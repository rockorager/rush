---
name: releasing-rush
description: Releases Rush with `just release`, which tags origin/main as the next semantic version so CI builds, publishes, and updates the AUR package. Use when cutting a release, picking a version, writing optional release notes, or checking a release's CI.
---

# Releasing Rush

Release tags are the versions. A release is a `vX.Y.Z` tag on a commit of
`main`; release often, whenever `main` has changes worth installing.

## How a release works

- `just release` releases `origin/main` as the newest tag's next patch version;
  `just release X.Y.Z` picks the version, which must be newer than every tag.
  It refuses when `origin/main` is already released or its CI run did not
  succeed.
- It commits `release: X.Y.Z` on top of `origin/main`, setting `.version` in
  `build.zig.zon` for builds from a source archive, tags that commit
  `vX.Y.Z`, and pushes the commit and tag atomically. It leaves the local
  checkout and branch untouched. If `main` moved since its fetch, nothing is
  pushed; run it again.
- `.github/workflows/release.yml` runs on the tag. It checks the tag against
  `build.zig.zon`, builds static `rush-X.Y.Z-{x86_64,aarch64}-linux.tar.xz`
  tarballs laid out for a `/usr` prefix, publishes them with `SHA256SUMS`, and
  then publishes `aur/rush-shell-bin` to the AUR with that version and those
  checksums. The AUR step needs the `AUR_SSH_PRIVATE_KEY` repository secret.
- The release description is `docs/releases/X.Y.Z.md` when it exists;
  otherwise it lists the commit subjects since the previous release.
- Builds of other commits derive their version from Git: an exact clean tag
  reports `X.Y.Z`, later commits `X.Y.(Z+1)-dev.<distance>+g<sha>`, and dirty
  worktrees append `.dirty`. No version needs bumping after a release.

## Steps

1. Confirm the version: the default next patch, or a minor or major version
   when the changes call for one.
2. Check that `origin/main` holds what should ship and that its CI passed:
   `gh run list --workflow ci.yml --commit "$(git rev-parse origin/main)"`.
3. For a release that deserves notes, write `docs/releases/X.Y.Z.md` and land
   it on `main` first. Notes stand alone, lead with user-visible impact, call
   out breaking changes and migrations, and contain no forge-specific links.
4. Run `just release` or `just release X.Y.Z`.
5. Watch the Release workflow through completion with `gh run watch`. Confirm
   the release page lists both tarballs and `SHA256SUMS`, and that the AUR
   job pushed `rush-shell-bin` X.Y.Z.

## Safety rules

- `just release` pushes to `main` and pushes a tag. Run it only with explicit
  approval for that release.
- Never move, replace, or delete a published tag without explicit approval and
  a clear explanation of the consequences. If the Release workflow fails,
  report the failure and fix forward with the next patch release.
- Do not edit published release notes except to correct a material factual
  error with an explicitly reviewed follow-up.
