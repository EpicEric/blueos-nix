{
  config,
  lib,
  blueosNixRev ? null,
  ...
}:
let
  cfg = config.services.blueos;
  inherit (lib) mkDefault mkOption types;

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
    assertions = [
      {
        assertion = cfg.package.passthru.version == version;
        message = "services.blueos.version does not match the version in services.blueos.package.";
      }
    ];

    system.nixos.label = lib.mkForce "blueos-${gitDescribe}-${config.system.nixos.version}";

    system.configurationRevision = mkDefault release.blueos_nix_revision;

    environment.etc."blueos/release.json".text = builtins.toJSON release;

    environment.variables.GIT_DESCRIBE_TAGS = mkDefault gitDescribe;
  };
}
