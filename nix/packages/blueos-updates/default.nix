{
  lib,
  rustPlatform,
  cacert,
  makeWrapper,
  nix,
  pkg-config,
  aws-lc,
  systemd,
}:
rustPlatform.buildRustPackage {
  pname = "blueos-updates";
  version = "0.1.0";

  src = ./.;

  cargoLock = {
    lockFile = ./Cargo.lock;
  };

  # nix-env, nix-store and switch-to-configuration are how a version is
  # installed and activated, so they have to be on PATH rather than assumed
  # from the host. systemd-run is what moves the switch out of this daemon's
  # cgroup, so it is required too rather than taken from the host.
  nativeBuildInputs = [
    makeWrapper
    pkg-config
  ];

  buildInputs = [ aws-lc ];

  postInstall = ''
    wrapProgram $out/bin/blueos-updates \
      --suffix PATH : ${
        lib.makeBinPath [
          nix
          systemd
        ]
      } \
      --set-default SSL_CERT_FILE ${cacert}/etc/ssl/certs/ca-bundle.crt
  '';

  meta = {
    description = "BlueOS update daemon, backed by NixOS generations";
    homepage = "https://github.com/BlueRobotics/BlueOS";
    license = lib.licenses.agpl3Plus;
    mainProgram = "blueos-updates";
    platforms = lib.platforms.linux;
  };
}
