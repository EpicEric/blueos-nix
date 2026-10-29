{
  lib,
  stdenv,
  fetchFromGitHub,
  meson,
  ninja,
  pkg-config,
  systemd,
  git,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "mavlink-router";
  version = "4";

  src = fetchFromGitHub {
    owner = "mavlink-router";
    repo = "mavlink-router";
    tag = "v${finalAttrs.version}";
    hash = "sha256-FPlR87EvmwRNt7OZUVsITgOL+WoW9LbnwHi18aHvXs0=";
  };

  # Upstream carries c_library_v2 as a git submodule, which fetchFromGitHub
  # does not populate.
  mavlinkC = fetchFromGitHub {
    owner = "mavlink";
    repo = "c_library_v2";
    rev = "92b1a43468e8737da2d4cc1e72304e6443dcfdd3";
    hash = "sha256-2x73nJluilJ2HSpa4/alSW2MPEGfUVTov1bw+Cw6PEo=";
  };

  patches = [ ./cstdint.patch ];

  postPatch = ''
    rm -rf modules/mavlink_c_library_v2
    cp -R ${finalAttrs.mavlinkC} modules/mavlink_c_library_v2
    chmod -R u+w modules/mavlink_c_library_v2
  '';

  nativeBuildInputs = [
    git
    meson
    ninja
    pkg-config
  ];

  buildInputs = [ systemd ];

  mesonFlags = [
    "-Dsystemdsystemunitdir=lib/systemd/system"
  ];

  # The build embeds `git describe` output for the version string; the sandbox
  # has no repository, so let meson fall back to the tarball version.
  env.MESON_ARGS = "-Dwrap_mode=nofallback";

  meta = {
    description = "MAVLink router and logger";
    homepage = "https://github.com/mavlink-router/mavlink-router";
    license = lib.licenses.asl20;
    mainProgram = "mavlink-routerd";
    platforms = lib.platforms.linux;
  };
})
