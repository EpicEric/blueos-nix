{
  callPackage,
  applyPatches,
  ardupilot-tools,
  bash,
  blueos-frontend,
  blueos-source,
  bridges,
  filebrowser,
  iproute2,
  lib,
  linux2rest,
  machineid-cli,
  makeWrapper,
  mavlink-router,
  mavlink-server,
  mavlink2rest,
  mavlink-camera-manager,
  mavp2p,
  nginx,
  procps,
  pyproject-build-systems,
  pyproject-nix,
  python311,
  systemd,
  ttyd,
  uv2nix,
  zenoh,
}:
let
  inherit (blueos-source) version rev channel;

  # applyPatches keeps the passthru of the source it wraps, so `tag` would be
  # null here: the source is pinned by commit, not by tag.
  src = applyPatches {
    name = "BlueOS-${version}-patched";
    src = blueos-source.src;
    patches = [
      ./cable-guy-dhcpcd.patch
      ./helper-nginx-paths.patch
      ./kraken-podman-pull.patch
      ./kraken-container-reuse.patch
      ./navigator-arch-detect.patch
      ./navigator-bmp390.patch
      ./navigator-nixos-serial-map.patch
      ./versionchooser-podman-pull.patch
    ];
  };

  workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = "${src}/core"; };

  overlay = workspace.mkPyprojectOverlay { sourcePreference = "wheel"; };

  setuptools =
    final: prev: name:
    prev.${name}.overrideAttrs (old: {
      nativeBuildInputs =
        (old.nativeBuildInputs or [ ]) ++ final.resolveBuildSystem { setuptools = [ ]; };
    });

  overrides = final: prev: {
    aiohttp = setuptools final prev "aiohttp";
    psutil = setuptools final prev "psutil";
    pykson = setuptools final prev "pykson";
    pyrsistent = setuptools final prev "pyrsistent";
    python-multipart = setuptools final prev "python-multipart";
    smbus2 = setuptools final prev "smbus2";
    pydantic = setuptools final prev "pydantic";
    sdbus = prev.sdbus.overrideAttrs (old: {
      buildInputs = (old.buildInputs or [ ]) ++ [ systemd ];
    });
  };

  pythonSet = (callPackage pyproject-nix.build.packages { python = python311; }).overrideScope (
    lib.composeManyExtensions [
      pyproject-build-systems.overlays.default
      overlay
      overrides
    ]
  );

  env = pythonSet.mkVirtualEnv "blueos-core-env" workspace.deps.default;

  # Each service is launched as `<service>/main.py` with its own directory on
  # sys.path, which is how they import their sibling modules.
  services = [
    "ardupilot_manager"
    "bag_of_holding"
    "beacon"
    "bridget"
    "cable_guy"
    "commander"
    "helper"
    "kraken"
    "log_zipper"
    "nmea_injector"
    "pardal"
    "ping"
    "versionchooser"
    "wifi"
  ];

  serviceScripts = lib.concatMapStringsSep "\n" (name: ''
    makeWrapper $out/bin/python $out/bin/${name} \
      --add-flags "${src}/core/services/${name}/main.py" \
      --prefix PYTHONPATH : "${src}/core/services/${name}" \
      --prefix PYTHONPATH : "${ardupilot-tools}/lib/python" \
      --prefix PATH : "${ardupilot-tools}/bin" \
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath [ systemd ]}"
  '') services;

  runtimePath = lib.makeBinPath [
    bridges
    filebrowser
    iproute2
    linux2rest
    machineid-cli
    mavlink-camera-manager
    mavlink-router
    mavlink-server
    mavlink2rest
    mavp2p
    nginx
    procps
    systemd
    ttyd
    zenoh
  ];
in
env.overrideAttrs (old: {
  pname = "blueos-core";

  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ makeWrapper ];

  # pyprojectMakeVenv runs this hook after it has built the venv into $out.
  postInstall = (old.postInstall or "") + ''
    ${serviceScripts}

    makeWrapper ${lib.getExe bash} $out/bin/start-blueos-core \
      --add-flags "${src}/core/start-blueos-core" \
      --prefix PATH : "${src}/core/services:${runtimePath}:$out/bin" \
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath [ systemd ]}"

    mkdir -p $out/share
    ln -s ${blueos-frontend}/share/blueos-frontend $out/share/blueos-frontend
  '';

  passthru = (old.passthru or { }) // {
    inherit env src blueos-frontend version rev channel;
  };
})
