{
  lib,
  rustPlatform,
  cacert,
  makeWrapper,
  nix,
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
  # from the host.
  nativeBuildInputs = [ makeWrapper ];

  postInstall = ''
    wrapProgram $out/bin/blueos-updates \
      --suffix PATH : ${lib.makeBinPath [ nix ]} \
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
