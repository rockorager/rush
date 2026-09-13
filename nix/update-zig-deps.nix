{
  coreutils,
  git,
  nixfmt,
  zon2nix,
  writeShellApplication,
  ...
}:
writeShellApplication {
  name = "update-rush-zig-deps";
  runtimeInputs = [
    coreutils
    git
    nixfmt
    zon2nix
  ];
  text = ''
    repo_root=$(git rev-parse --show-toplevel)
    target="$repo_root/nix/zig-deps.nix"
    generated=$(mktemp --suffix=.nix)
    trap 'rm -f "$generated"' EXIT

    zon2nix "$repo_root/build.zig.zon" > "$generated"
    nixfmt "$generated"

    if cmp -s "$generated" "$target"; then
      echo "Zig dependencies are already up to date."
    else
      install -m 0644 "$generated" "$target"
      echo "Updated nix/zig-deps.nix."
    fi
  '';
}
