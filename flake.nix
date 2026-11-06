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

      # The packages that compile native code, which is what makes a build slow.
      compiledPackages = pkgs: {
        bridges = pkgs.callPackage ./nix/packages/bridges { };

        linux2rest = pkgs.callPackage ./nix/packages/linux2rest { };

        machineid-cli = pkgs.callPackage ./nix/packages/machineid-cli { };

        mavlink-router = pkgs.callPackage ./nix/packages/mavlink-router { };

        mavlink-server = pkgs.callPackage ./nix/packages/mavlink-server { };

        mavlink2rest = pkgs.callPackage ./nix/packages/mavlink2rest { };

        mavlink-camera-manager = pkgs.callPackage ./nix/packages/mavlink-camera-manager { };

        mavp2p = pkgs.callPackage ./nix/packages/mavp2p { };
      };

      crossPkgs = nixpkgs.legacyPackages.x86_64-linux.pkgsCross.aarch64-multiplatform;

      # mavlink-router only links libsystemd and builds in a minute under QEMU,
      # while cross-building it compiles systemd from source: cross-built
      # libraries are not in cache.nixos.org.
      crossPackages = removeAttrs (compiledPackages crossPkgs) [ "mavlink-router" ] // {
        # The module names this option `updates`, so the key has to match it for
        # a cross build to pick the cross-compiled daemon over the native one.
        updates = crossPkgs.callPackage ./nix/packages/blueos-updates { };

        mavlink-camera-manager = crossPkgs.callPackage ./nix/packages/mavlink-camera-manager {
          pkgsNative = nixpkgs.legacyPackages.aarch64-linux;
        };
      };

      # One SD image per supported board. nixos-hardware supplies the kernel and
      # the firmware partition handling; the board file only adds what the
      # Navigator needs on top.
      #
      # With `cross`, the system is still evaluated as native aarch64-linux so
      # everything else substitutes from cache.nixos.org. Only the kernel and the
      # compiled BlueOS packages are built on x86_64, which skips the QEMU
      # emulation that makes them slow.
      mkBlueOS =
        {
          board,
          cross ? false,
        }:
        lib.nixosSystem {
          system = "aarch64-linux";
          specialArgs = {
            blueos =
              if cross then
                self.packages.aarch64-linux.blueos-core.override crossPackages
              else
                self.packages.aarch64-linux.blueos-core;
            sdImageModule = "${nixpkgs}/nixos/modules/installer/sd-card/sd-image.nix";
            # The flake's own U-Boot build, which has the bootcount fallback the
            # stock package lacks. Passed as an argument because the module's
            # `pkgs` is nixpkgs, which does not know about this repo's packages.
            # Resolved from the board's own package set so that a native ARM
            # runner builds it natively and an x86_64 one cross-compiles it.
            ubootPackage =
              if cross then
                crossPkgs.callPackage ./nix/packages/uboot-rpi { }
              else
                nixpkgs.legacyPackages.aarch64-linux.callPackage ./nix/packages/uboot-rpi { };
            # Null for a dirty tree and for a plain path flake; version.nix
            # reports that as "unknown" rather than failing the build.
            blueosNixRev = self.rev or self.dirtyRev or null;
          };
          modules = [
            ./nix/modules/blueos
            nixos-hardware.nixosModules."raspberry-pi-${board}"
            ./nix/nixos/rpi/pi${board}
            {
              services.blueos.board = "pi${board}";
              # Where the image workflow publishes what it cached, so a device
              # that boots this image can offer its own successors. Written out
              # rather than derived: Nix evaluates this without knowing which
              # repository it is being read from, which is also why a fork
              # publishing its own builds has to override it.
              # services.blueos.updates.manifestUrl =
              #   "https://raw.githubusercontent.com/EpicEric/blueos-nix/manifest/manifest.json";
            }
          ]
          ++ lib.optional cross (
            { pkgs, ... }:
            {
              services.blueos.packages = crossPackages;

              boot.kernelPackages = pkgs.linuxPackagesFor (
                crossPkgs.callPackage "${nixos-hardware}/raspberry-pi/common/kernel.nix" {
                  rpiVersion = lib.toInt board;
                }
              );
            }
          );
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

          blueos-updates = pkgs.callPackage ./nix/packages/blueos-updates { };

          blueos-core = pkgs.callPackage ./nix/packages/blueos-core {
            inherit
              pyproject-nix
              uv2nix
              pyproject-build-systems
              ;

            inherit (self.packages.${system})
              ardupilot-tools
              blueos-source
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
            imports = [ ./nix/modules/blueos ];

            services.blueos.package = self.packages.${pkgs.stdenv.hostPlatform.system}.blueos-core;
          };

        default = self.nixosModules.blueos;
      };

      nixosConfigurations = {
        blueos-pi4 = mkBlueOS { board = "4"; };
        blueos-pi5 = mkBlueOS { board = "5"; };
        blueos-pi4-cross = mkBlueOS {
          board = "4";
          cross = true;
        };
        blueos-pi5-cross = mkBlueOS {
          board = "5";
          cross = true;
        };
      };
    };
}
