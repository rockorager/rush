# Rush Nix Components

This project can be built with nix using the artifacts found here.

## Installing Rush with Nix

The flake output provides the necessary package derivation, with the flake and zig locks provided and integrated.

Outputs work exactly like any other nix flake:

```nix
{
    name = "Example Flake";
 
    # Add Rush to the inputs
    inputs = {
        nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
        rush.url = "github:rockorager/rush"; # This repository
    };

    # The Flake Inputs set are passed explicitly as arguments
    # The `@ inputs` also allows you to capture the full set as well
    # Either one is fine depend on needs, this verbose example is redundant
    #  just to showcase both
    outputs = {self, nixpkgs, rush} @ inputs: {
        # The `exampleHost` is the actual hostname
        # and this is the function that creates the nixos system config
        nixosConfigurations.exampleHost = nixpkgs.lib.nixosSystem {
            system = "x86_64-linux"; # Match to your real system type, this is x86/amd64 and is most common
            # How we will pass the inputs to the rest of the system's nixos modules
            specialArgs = {inherit inputs;};
            modules = [
                # Include your base configs
                ./configuration.nix
                ./hardware-configuration.nix
                # Include our extra modules too
                ./example-module.nix
                ./example-user-module.nix
                # Modules can be inlined as well
                # This is setting the hostname, where everything in the `{}`
                #  is what is in a normal nixos module
                ({networking.hostName = "exampleHost";})
            ];
        };
    }
}

```

Assuming you use a nixos configuration where you pass inputs as a SpecialArg (a common practice):

```nix
# example_module.nix
# Rush will be available in the inputs list now since they were in `specialArgs`
{inputs, pkgs, ...}: {
    # Add to your packages list
    # The ${pkgs} variable is a way of automatically detecting and using the right system variable
    environment.systemPackages = [
        inputs.rush.packages.${pkgs.stdenv.hostPlatform.system}.rush-shell
    ];
}
```

You can also make it your default shell if you would like:

```nix
# example_user_module.nix
{inputs, pkgs, ...}: {
    # Setting the package reference will make Rush your login shell
    users.users.example.shell = inputs.rush.packages.${pkgs.stdenv.hostPlatform.system}.rush-shell;
}
```

## Building Rush with Nix

The Zig depedencies have a provided linkfarm using Zon2Nix that locks them.

The flake provides both the shell build and the mechanism to update the nix-provided Zig dependencies.

For nix-command and nix flake users:
```bash
nix run .#update-zig-deps
nix build .
```

The Zig dependencies are based on the project's dependencies itself and may need updating if you pulled
from the project's `main` branch.

