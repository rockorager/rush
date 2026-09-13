{
  description = "Rockorager's User-friendly Shell Flake";

  inputs.nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = forAllSystems (system: import nixpkgs { inherit system; });
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor.${system};
        in
        {
          default = pkgs.callPackage ./nix/package.nix { };
          rush-shell = self.packages.${system}.default;
        }
      );

      apps = forAllSystems (
        system:
        let
          pkgs = pkgsFor.${system};
        in
        {
          update-zig-deps = {
            type = "app";
            program = nixpkgs.lib.getExe (pkgs.callPackage ./nix/update-zig-deps.nix { });
            meta.description = "Regenerate the Nix expression for Rush's Zig dependencies";
          };
        }
      );
    };
}
