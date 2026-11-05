{
  description = "Packages used by BlueOS";

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
        bridges = pkgs.callPackage ./packages/bridges { };

        linux2rest = pkgs.callPackage ./packages/linux2rest { };

        machineid-cli = pkgs.callPackage ./packages/machineid-cli { };

        mavlink-router = pkgs.callPackage ./packages/mavlink-router { };

        mavlink-server = pkgs.callPackage ./packages/mavlink-server { };

        mavlink2rest = pkgs.callPackage ./packages/mavlink2rest { };

        mavlink-camera-manager = pkgs.callPackage ./packages/mavlink-camera-manager { };

        mavp2p = pkgs.callPackage ./packages/mavp2p { };
      };

      crossPkgs = nixpkgs.legacyPackages.x86_64-linux.pkgsCross.aarch64-multiplatform;

      # mavlink-router only links libsystemd and builds in a minute under QEMU,
      # while cross-building it compiles systemd from source: cross-built
      # libraries are not in cache.nixos.org.
      crossPackages = removeAttrs (compiledPackages crossPkgs) [ "mavlink-router" ] // {
        mavlink-camera-manager = crossPkgs.callPackage ./packages/mavlink-camera-manager {
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
                crossPkgs.callPackage ./packages/uboot-rpi { }
              else
                nixpkgs.legacyPackages.aarch64-linux.callPackage ./packages/uboot-rpi { };
            # Null for a dirty tree and for a plain path flake; version.nix
            # reports that as "unknown" rather than failing the build.
            blueosNixRev = self.rev or self.dirtyRev or null;
          };
          modules = [
            ./modules/blueos
            nixos-hardware.nixosModules."raspberry-pi-${board}"
            ./nixos/pi${board}
            {
              services.blueos.board = "pi${board}";
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
          blueos-source = pkgs.callPackage ./packages/blueos-source { };

          blueos-frontend = pkgs.callPackage ./packages/blueos-frontend {
            inherit (self.packages.${system}) blueos-source;
          };

          ardupilot-tools = pkgs.callPackage ./packages/ardupilot-tools { };

          blueos-updates = pkgs.callPackage ./packages/blueos-updates { };

          blueos-core = pkgs.callPackage ./packages/blueos-core {
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
            imports = [ ./modules/blueos ];

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
