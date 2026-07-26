{
  description = "Rockorager's User-friendly Shell Flake";

  inputs.nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";

  outputs = {self, nixpkgs}: let
    forAllSystems = nixpkgs.lib.genAttrs ["x86_64-linux" "aarch64-linux" "aarch64-darwin"];
    p = forAllSystems (system: import nixpkgs {inherit system;});
  in {
    packages = forAllSystems (
      system: {
        default = import ./nix/package.nix {pkgs = p.${system};};
        rush-shell = self.packages.${system}.default;
      }
    );
  };
}
