{
  lib,
  rustPlatform,
  fetchFromGitHub,
  cmake,
  git,
  gzip,
  pkg-config,
  openssl,
}:
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "mavlink-server";
  version = "0.11.1";

  src = fetchFromGitHub {
    owner = "bluerobotics";
    repo = "mavlink-server";
    tag = finalAttrs.version;
    hash = "sha256-BOvG1DWpzq3C208Cuwq6+OgQaZsoRsVEpJWpLLcU0YI=";
  };

  cargoLock = {
    lockFile = ./Cargo.lock;
    outputHashes = {
      "include_dir-0.7.4" = "sha256-nuxK7up+JrSWWAwsbEM9wt+usDR65/p69ZQa/8uSccw=";
      "include_dir_macros-0.7.4" = "sha256-nuxK7up+JrSWWAwsbEM9wt+usDR65/p69ZQa/8uSccw=";
      "mavlink-codec-0.1.0" = "sha256-Z33CEKNSc9ven/7OUe4Ykiom+BaMjCweaTrNvgcWLC8=";
    };
  };

  nativeBuildInputs = [
    cmake
    git
    gzip
    pkg-config
  ];

  buildInputs = [ openssl ];

  # include_dir is vendored as a flat directory, so its `include_str!("../../README.md")`,
  # which resolves inside the upstream workspace, points one level above the vendor
  # root. Only used for a doc attribute, so an empty placeholder is enough.
  postPatch = ''
    touch "$NIX_BUILD_TOP/cargo-vendor-dir/README.md"
  '';

  # The build script shells out to gzip and uses `git describe` for its version
  # string, neither of which the sandbox provides by default.
  env.SKIP_FRONTEND = "1";

  # The TCP integration tests share a process-global driver registry and register
  # the same endpoint uuids, so they must not run concurrently.
  checkFlags = [
    "--"
    "--test-threads=1"
  ];

  nativeInstallCheckInputs = [ ];

  meta = {
    description = "MAVLink server with a web interface";
    homepage = "https://github.com/bluerobotics/mavlink-server";
    license = lib.licenses.mit;
    mainProgram = "mavlink-server";
    platforms = lib.platforms.linux;
  };
})
