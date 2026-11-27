{
  description = "Package manager for Modrinth projects";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # dub can't download in the Nix sandbox. Keep the tag in step with
    # dub.selections.json.
    cmd = {
      url = "github:modpm/cmd/v0.4.0";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      cmd,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      version = nixpkgs.lib.fileContents ./VERSION;
    in
    {
      packages = forAllSystems (pkgs: rec {
        modpm = pkgs.callPackage ./packaging/nix/package.nix {
          src = self;
          inherit cmd version;
        };
        default = modpm;
      });

      overlays.default = final: _prev: {
        modpm = final.callPackage ./packaging/nix/package.nix {
          src = self;
          inherit cmd version;
        };
      };

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.ldc
            pkgs.dub
            pkgs.curl
          ];
        };
      });
    };
}
