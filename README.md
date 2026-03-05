# Twintail Launcher Flake

This is a flake that provides a Nix package for Twintail Launcher, a free and open-source launcher for anime games.

### Running

Make sure you have Nix installed, then run:

```sh
nix run github:Tw1ZZLER/twintail-launcher-flake
```

To run the launcher.

### Building

Make sure you have Nix installed, then run:

```sh
nix build github:Tw1ZZLER/twintail-launcher-flake
```

To build the package.

### Installation

1. **Add the flake as an input** in your config flake:

```nix
inputs = {
  twintail-launcher.url = "github:Tw1ZZLER/twintail-launcher-flake";
  # ...
};
```

2. **Pass `inputs` to your modules** via `specialArgs` / `extraSpecialArgs`:

```nix
# NixOS:
nixpkgs.lib.nixosSystem {
  specialArgs = { inherit inputs; };
  # ...
};

# Standalone Home Manager:
home-manager.lib.homeManagerConfiguration {
  extraSpecialArgs = { inherit inputs; };
  # ...
};

# Home Manager as a NixOS module:
home-manager.extraSpecialArgs = { inherit inputs; };
```

3. **Add the package** in your configuration:

```nix
{ inputs, pkgs, ... }:

{
  # In a NixOS module:
  environment.systemPackages = [
    inputs.twintail-launcher.packages.${pkgs.system}.default
  ];

  # Or in a Home Manager module:
  home.packages = [
    inputs.twintail-launcher.packages.${pkgs.system}.default
  ];
}
```

> **Tip:** Replace `default` with `twintaillauncher` to build from source instead of using the pre-built binary.

### Available Packages

| Package                | Description                                                        |
| ---------------------- | ------------------------------------------------------------------ |
| `twintaillauncher-bin` | Pre-built binary extracted from the GitHub Releases `.deb` (default) |
| `twintaillauncher`     | Built from source using Crane — useful for development              |

### Development Shell

This flake provides a development shell with all the build dependencies available.
After cloning, simply run:

```sh
nix develop
```
