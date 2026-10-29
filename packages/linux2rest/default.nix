{
  fetchFromGitHub,
  fetchurl,
  lib,
  openssl,
  pkg-config,
  rustPlatform,
  udev,
}:
let
  version = "0.6.5";

  # build.rs downloads Vue at build time, which the sandbox forbids; the patch
  # drops the download and the file is supplied from a fixed-output fetch instead.
  vue = fetchurl {
    url = "https://unpkg.com/vue@3.0.5/dist/vue.global.js";
    hash = "sha256-Wr5PnkpmZ3oQFRZLfDrI6fsePSMak5h8rW2rqq+mdWg=";
  };
in
rustPlatform.buildRustPackage {
  pname = "linux2rest";
  inherit version;

  src = fetchFromGitHub {
    owner = "patrickelectric";
    repo = "linux2rest";
    tag = "v${version}";
    hash = "sha256-89hbNFCFflsylHjYMPs+auQazpTdQxSG0qaMV7uSVQ0=";
  };

  cargoLock = {
    lockFile = ./Cargo.lock;
    outputHashes = {
      "tracing-appender-0.2.2-with-filename-suffix" =
        "sha256-fUau1OWoiUI9ip8dS8JGt7iqTcGBEk7DQzLwUmJJJBU=";
    };
  };

  nativeBuildInputs = [ pkg-config ];

  patches = [ ./no-download.patch ];

  postPatch = ''
    cp ${./Cargo.lock} Cargo.lock
    cp ${vue} src/html/vue.js
  '';

  buildInputs = [
    openssl
    udev
  ];

  meta = {
    description = "REST API exposing Linux system information";
    homepage = "https://github.com/patrickelectric/linux2rest";
    license = lib.licenses.mit;
    mainProgram = "linux2rest";
    platforms = lib.platforms.linux;
  };
}
