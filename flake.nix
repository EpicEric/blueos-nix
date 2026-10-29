{
  description = "Packages used by BlueOS";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.zst";
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      pyproject-nix,
      uv2nix,
      pyproject-build-systems,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      forAllSystems = lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
      ];
    in
    {
      packages = forAllSystems (system: {
        default = self.packages.${system}.blueos-core;

        blueos-core = nixpkgs.legacyPackages.${system}.callPackage ./packages/blueos-core {
          inherit
            pyproject-nix
            uv2nix
            pyproject-build-systems
            ;
        };

        mavlink-camera-manager =
          nixpkgs.legacyPackages.${system}.callPackage ./packages/mavlink-camera-manager.nix
            { };

        linux2rest = nixpkgs.legacyPackages.${system}.callPackage ./packages/linux2rest { };
      });
    };
}
