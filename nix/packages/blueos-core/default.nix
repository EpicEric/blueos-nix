{
  callPackage,
  applyPatches,
  ardupilot-tools,
  bash,
  blueos-frontend,
  blueos-recorder,
  blueos-source,
  bridges,
  disktest,
  filebrowser,
  gst_all_1,
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
  mcap,
  mcap-foxglove-video-extract,
  nginx,
  procps,
  pyproject-build-systems,
  pyproject-nix,
  python311,
  swagger-ui,
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
      ./helper-nixos-factory-mode.patch
      ./navigator-bmp390.patch
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

  # The pinned pyproject sets `tool.uv.default-groups = [ "dev" "lint" ]`,
  # and deps.default maps that straight into the venv: it would install pytest,
  # pylint and mypy into the runtime environment. An empty spec installs each
  # package's own dependencies, which is what the container's
  # `uv sync --no-default-groups` does.
  env = pythonSet.mkVirtualEnv "blueos-core-env" { blueos-core = [ ]; };

  # Each service is launched as `<service>/main.py` with its own directory on
  # sys.path, which is how they import their sibling modules. This is the set
  # the Python wrappers are built for; it is not the same as the list of units,
  # since some entries of core/start-blueos-core are not Python services.
  services = [
    "ardupilot_manager"
    "bag_of_holding"
    "beacon"
    "bridget"
    "cable_guy"
    "commander"
    "customization"
    "disk_usage"
    "helper"
    "kraken"
    "nmea_injector"
    "pardal"
    "ping"
    "recorder_extractor"
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
    ardupilot-tools
    blueos-recorder
    bridges
    disktest
    filebrowser
    gst_all_1.gst-plugins-base
    iproute2
    linux2rest
    machineid-cli
    mavlink-camera-manager
    mavlink-router
    mavlink-server
    mavlink2rest
    mavp2p
    mcap
    mcap-foxglove-video-extract
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
    ln -s ${swagger-ui} $out/share/swagger-ui
  '';

  passthru = (old.passthru or { }) // {
    inherit
      env
      src
      blueos-frontend
      swagger-ui
      version
      rev
      channel
      ;
  };
})
