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

  cargoLock.lockFile = ./Cargo.lock;

  nativeBuildInputs = [
    makeWrapper
    pkg-config
  ];

  buildInputs = [ aws-lc ];

  # The daemon shells out to these, so they come from the wrapper rather than
  # the host. systemd-run is what moves the switch out of this daemon's cgroup.
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
