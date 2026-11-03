# What this build is. Everything downstream (the version chooser, the motd,
# the host log dumps, Sentry) reads its identity from here, so a generation
# answers "which BlueOS is this?" without evaluating any Nix.
{
  config,
  lib,
  blueosNixRev ? null,
  ...
}:
let
  cfg = config.services.blueos;
  inherit (lib) mkDefault mkOption types;

  # The BlueOS side comes from the package, so it cannot disagree with the
  # code inside it. The blueos-nix side is only known to the flake.
  version = cfg.version;
  revision = cfg.revision;

  gitDescribe = "${version}-0-g${builtins.substring 0 7 revision}";

  release = {
    inherit version revision;
    channel = cfg.channel;
    blueos_nix_revision = if blueosNixRev == null then "unknown" else blueosNixRev;
  };
in
{
  options.services.blueos = {
    gitDescribe = mkOption {
      type = types.str;
      internal = true;
      readOnly = true;
      default = gitDescribe;
      defaultText = lib.literalMD "the version and revision, in `git describe` form";
      description = "Version string in the `<version>-0-g<rev>` form the Docker image used.";
    };

    version = mkOption {
      type = types.str;
      default = cfg.package.passthru.version;
      defaultText = lib.literalMD "the version in the `blueos-core` package";
      description = "BlueOS version this system runs, reported by the UI and the version chooser.";
    };

    revision = mkOption {
      type = types.str;
      default = cfg.package.passthru.rev;
      defaultText = lib.literalMD "the commit in the `blueos-core` package";
      description = "BlueOS commit this system was built from.";
    };

    channel = mkOption {
      type = types.str;
      default = cfg.package.passthru.channel;
      defaultText = lib.literalMD "the channel in the `blueos-core` package";
      description = "Release channel, such as stable, beta or dev.";
    };
  };

  config = lib.mkIf cfg.enable {
    # mkForce because the default label leads with the nixpkgs version, which
    # says nothing about which BlueOS the vehicle is running. The nixpkgs
    # version is kept in the label too, since it is the only hint a bug report
    # from the boot menu would otherwise carry.
    system.nixos.label = lib.mkForce "blueos-${gitDescribe}-${config.system.nixos.version}";

    system.configurationRevision = mkDefault release.blueos_nix_revision;

    # Inside the generation, so it is atomic with the code and readable from
    # /run/current-system without touching the profile or evaluating Nix.
    environment.etc."blueos/release.json".text = builtins.toJSON release;

    # Read by commonwealth.utils.general.blueos_version(), which feeds the
    # helper's heartbeat and the host log dumps. Sentry only enables itself for
    # strings matching ^\d+\.\d+\.\d+-\d+-g[0-9a-f]{7,}$, which is why this is
    # built from the version and revision rather than left unset.
    environment.variables.GIT_DESCRIBE_TAGS = mkDefault gitDescribe;

    # blueos-core carries the frontend, so the version the frontend was built
    # with has to match it.
    assertions = [
      {
        assertion = cfg.package.passthru.version == version;
        message = "services.blueos.version does not match the version in services.blueos.package.";
      }
    ];
  };
}
