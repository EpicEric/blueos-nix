{
  description = "Packages used by BlueOS";

  nixConfig = {
    extra-substituters = [ "https://cache.eric.dev.br" ];
    extra-trusted-public-keys = [
      "cache.eric.dev.br-1:szEyq5LCjxDCUHYSRaSFU5HdHmR7QlT+FRG3tB9QtpE="
    ];
  };

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.zst";
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

      compiledPackages = pkgs: {
        bridges = pkgs.callPackage ./nix/packages/bridges { };

        blueos-recorder = pkgs.callPackage ./nix/packages/blueos-recorder { };

        disktest = pkgs.callPackage ./nix/packages/disktest { };

        linux2rest = pkgs.callPackage ./nix/packages/linux2rest { };

        machineid-cli = pkgs.callPackage ./nix/packages/machineid-cli { };

        mavlink-router = pkgs.callPackage ./nix/packages/mavlink-router { };

        mavlink-server = pkgs.callPackage ./nix/packages/mavlink-server { };

        mavlink2rest = pkgs.callPackage ./nix/packages/mavlink2rest { };

        mavlink-camera-manager = pkgs.callPackage ./nix/packages/mavlink-camera-manager { };

        mavp2p = pkgs.callPackage ./nix/packages/mavp2p { };

        mcap = pkgs.mcap-cli;

        mcap-foxglove-video-extract = pkgs.callPackage ./nix/packages/mcap-foxglove-video-extract { };

        zenoh = pkgs.callPackage ./nix/packages/zenoh { };

        zenoh-backend-filesystem = pkgs.callPackage ./nix/packages/zenoh-backend-filesystem { };

        zenoh-plugin-remote-api = pkgs.callPackage ./nix/packages/zenoh-plugin-remote-api { };
      };

      mkBlueOS =
        { board }:
        lib.nixosSystem {
          system = "aarch64-linux";
          specialArgs = {
            blueos = self.packages.aarch64-linux.blueos-core;
            sdImageModule = "${nixpkgs}/nixos/modules/installer/sd-card/sd-image.nix";
            ubootPackage = self.packages.aarch64-linux.uboot-rpi;
            blueosNixRev = self.rev or self.dirtyRev or null;
          };
          modules = [
            ./nix/modules/blueos
            nixos-hardware.nixosModules."raspberry-pi-${board}"
            ./nix/nixos/rpi/pi${board}
            {
              services.blueos.board = "pi${board}";
              services.blueos.updates.manifestUrl = "https://epiceric.github.io/blueos-nix/manifest.json";
            }
          ];
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        compiledPackages pkgs
        // {
          blueos-source = pkgs.callPackage ./nix/packages/blueos-source { };

          blueos-frontend = pkgs.callPackage ./nix/packages/blueos-frontend {
            inherit (self.packages.${system}) blueos-source;
          };

          ardupilot-tools = pkgs.callPackage ./nix/packages/ardupilot-tools { };

          swagger-ui = pkgs.callPackage ./nix/packages/swagger-ui { };

          blueos-updates = pkgs.callPackage ./nix/packages/blueos-updates { };

          blueos-core = pkgs.callPackage ./nix/packages/blueos-core {
            inherit
              pyproject-nix
              uv2nix
              pyproject-build-systems
              ;

            inherit (self.packages.${system})
              ardupilot-tools
              blueos-recorder
              blueos-source
              blueos-frontend
              bridges
              disktest
              linux2rest
              machineid-cli
              mavlink-router
              mavlink-server
              mavlink2rest
              mavlink-camera-manager
              mavp2p
              mcap
              mcap-foxglove-video-extract
              swagger-ui
              zenoh
              ;
          };

          default = self.packages.${system}.blueos-core;
        }

        // lib.optionalAttrs (system == "aarch64-linux") {
          uboot-rpi = pkgs.callPackage ./nix/packages/uboot-rpi { };
        }
      );

      nixosModules = {
        blueos =
          { pkgs, ... }:
          {
            imports = [ ./nix/modules/blueos ];

            services.blueos.package = self.packages.${pkgs.stdenv.hostPlatform.system}.blueos-core;
          };

        default = self.nixosModules.blueos;
      };

      nixosConfigurations = {
        blueos-pi4 = mkBlueOS { board = "4"; };
        blueos-pi5 = mkBlueOS { board = "5"; };
      };
    };
}
