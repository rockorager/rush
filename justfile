# rush: a POSIX shell. `just --list` shows the recipes; AGENTS.md holds the
# working conventions.

[private]
default:
    @just --list

[doc("Build rush into zig-out/bin/rush")]
[group("build")]
build *ARGS:
    zig build {{ ARGS }}

[doc("Install a release build of rush under PREFIX")]
[group("build")]
install prefix="~/.local":
    zig build install -Doptimize=ReleaseSafe -Dregister-shell=false --prefix {{ prefix }}

[doc("Build and run rush")]
[group("build")]
run *ARGS:
    zig build run -- {{ ARGS }}

[doc("Release origin/main as vVERSION, the next patch version by default; CI builds and publishes it")]
[group("release")]
release version="":
    #!/usr/bin/env bash
    set -euo pipefail
    git fetch -q --tags origin main
    sha=$(git rev-parse origin/main)
    if tag=$(git describe --exact-match --tags --match 'v[0-9]*' "$sha" 2>/dev/null); then
        echo "origin/main is released already, as $tag" >&2
        exit 1
    fi
    # Only a commit whose CI passed is released.
    ci=$(gh run list --workflow ci.yml --commit "$sha" --json conclusion --jq '.[0].conclusion // "missing"')
    if [ "$ci" != success ]; then
        echo "CI for origin/main ${sha:0:8} is $ci, not success" >&2
        exit 1
    fi
    # The tags are the versions: the newest's patch, one up, unless told.
    last=$(git tag -l 'v[0-9]*' --sort=-v:refname | head -1)
    version="{{ version }}"
    if [ -z "$version" ]; then
        IFS=. read -r major minor patch <<<"${last:-v0.0.0}"
        version=${major#v}.$minor.$((patch + 1))
    fi
    if ! [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "version $version is not X.Y.Z" >&2
        exit 1
    fi
    if [ -n "$last" ] && [ "$(printf '%s\n' "$last" "v$version" | sort -V | tail -1)" != "v$version" ]; then
        echo "v$version is not newer than $last" >&2
        exit 1
    fi
    # The release commit records the version in build.zig.zon for builds from a
    # source archive. It is written with a scratch index, so this checkout and
    # its branch stay as they are.
    index=$(mktemp)
    trap 'rm -f "$index"' EXIT
    export GIT_INDEX_FILE=$index
    git read-tree "$sha"
    zon=$(git show "$sha:build.zig.zon" |
        sed "s/^    \.version = \"[^\"]*\",\$/    .version = \"$version\",/" |
        git hash-object -w --stdin)
    git update-index --cacheinfo "100644,$zon,build.zig.zon"
    tree=$(git write-tree)
    unset GIT_INDEX_FILE
    commit=$(git commit-tree "$tree" -p "$sha" -m "release: $version")
    git diff --stat "$sha" "$commit"
    git tag -a "v$version" -m "Rush $version" "$commit"
    # Atomically, so main never gets a release commit without its tag. If main
    # moved since the fetch, nothing is pushed and the tag goes too.
    if ! git push -q --atomic origin "$commit:refs/heads/main" "v$version"; then
        git tag -d "v$version" >/dev/null
        exit 1
    fi
    echo "pushed v$version; the Release workflow builds and publishes it:"
    echo "https://github.com/rockorager/rush/actions/workflows/release.yml"

[doc("The unit tests")]
[group("test")]
test *ARGS:
    zig build test {{ ARGS }}

[doc("The POSIX conformance suite")]
[group("test")]
conformance *ARGS:
    zig build conformance -- {{ ARGS }}

[doc("The terminal tests")]
[group("test")]
terminal *ARGS:
    zig build terminal {{ ARGS }}

[doc("Check formatting of Zig and this justfile")]
[group("lint")]
lint:
    zig fmt --check build.zig build.zig.zon src tests fuzz
    just --unstable --fmt --check

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    zig fmt build.zig build.zig.zon src tests fuzz
    just --unstable --fmt

[doc("Everything CI runs on Linux")]
[group("ci")]
ci: lint
    zig build compile-check
    zig build test
    zig build conformance
    zig build terminal
