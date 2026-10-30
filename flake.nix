{
  description = "Packages used by BlueOS";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.zst";
    nixos-hardware = {
      url = "github:NixOS/nixos-hardware";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
      nixos-hardware,
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

      # One SD image per supported board. nixos-hardware supplies the kernel and
      # the firmware partition handling; the board file only adds what the
      # Navigator needs on top.
      mkBlueOS =
        board:
        lib.nixosSystem {
          system = "aarch64-linux";
          specialArgs = {
            blueos = self.packages.aarch64-linux.blueos-core;
            sdImageModule =
              "${nixpkgs}/nixos/modules/installer/sd-card/sd-image.nix";
          };
          modules = [
            ./modules/blueos
            nixos-hardware.nixosModules."raspberry-pi-${board}"
            ./nixos/pi${board}
          ];
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          blueos-frontend = pkgs.callPackage ./packages/blueos-frontend { };

          ardupilot-tools = pkgs.callPackage ./packages/ardupilot-tools { };

          bridges = pkgs.callPackage ./packages/bridges { };

          linux2rest = pkgs.callPackage ./packages/linux2rest { };

          machineid-cli = pkgs.callPackage ./packages/machineid-cli { };

          mavlink-router = pkgs.callPackage ./packages/mavlink-router { };

          mavlink-server = pkgs.callPackage ./packages/mavlink-server { };

          mavlink2rest = pkgs.callPackage ./packages/mavlink2rest { };

          mavlink-camera-manager = pkgs.callPackage ./packages/mavlink-camera-manager { };

          mavp2p = pkgs.callPackage ./packages/mavp2p { };

          blueos-core = pkgs.callPackage ./packages/blueos-core {
            inherit
              pyproject-nix
              uv2nix
              pyproject-build-systems
              ;

            inherit (self.packages.${system})
              ardupilot-tools
              blueos-frontend
              bridges
              linux2rest
              machineid-cli
              mavlink-router
              mavlink-server
              mavlink2rest
              mavlink-camera-manager
              mavp2p
              ;
          };

          default = self.packages.${system}.blueos-core;
        }
      );

      nixosModules = {
        blueos =
          { pkgs, ... }:
          {
            imports = [ ./modules/blueos ];

            services.blueos.package = self.packages.${pkgs.stdenv.hostPlatform.system}.blueos-core;
          };

        default = self.nixosModules.blueos;
      };

      nixosConfigurations = {
        blueos-pi4 = mkBlueOS "4";
        blueos-pi5 = mkBlueOS "5";
      };
    };
}
