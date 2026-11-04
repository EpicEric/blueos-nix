{
  lib,
  bun,
  blueos-source,
  fetchFromGitHub,
  nodejs,
  stdenvNoCC,
  writableTmpDirAsHomeHook,
}:
let
  inherit (blueos-source) version src rev;

  # Submodules are not part of the GitHub archive; the revisions match the ones
  # the tag records in .gitmodules.
  submodules = {
    "core/frontend/public/assets/ArduPilot-Parameter-Repository" = fetchFromGitHub {
      owner = "ArduPilot";
      repo = "ParameterRepository";
      rev = "56888d375a118e4ca1df580886ee3c5ec2cbc9fd";
      hash = "sha256-Qkf6h9J5NKPnssSu8sMxtACKaCE4psy1i+glgNSbnqw=";
    };
    "core/frontend/src/PX4-parameters" = fetchFromGitHub {
      owner = "patrickelectric";
      repo = "PX4-parameters";
      rev = "88ff1308c068168998cdf53702ebfbf271860a4f";
      hash = "sha256-SRTzNhHxafZTkcaNlQIaNT0Qqov0BFPMgAtMyX2tJBM=";
    };
    "core/frontend/src/components/vue-tour" = fetchFromGitHub {
      owner = "pulsardev";
      repo = "vue-tour";
      rev = "a6bf7324224f2d817a2ade108e200d03ee391075";
      hash = "sha256-K1sIp6N6JVcBLUmREFrJF3nX8Jx/NR4IOys8a4mcMBk=";
    };
    "core/frontend/src/libs/MAVLink2Rest/mavlink2rest-ts" = fetchFromGitHub {
      owner = "patrickelectric";
      repo = "mavlink2rest-ts";
      rev = "0d43361847a3cdd36609e504182c603464086b8e";
      hash = "sha256-hOgtmTvxY7BcELYXnPyTjD1BvWRc3LR8By4r+iVXNYo=";
    };
  };

  submoduleCopy = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (path: submodule: ''
      rm -rf ${path}
      cp -R ${submodule} ${path}
    '') submodules
  );

  nodeModules = stdenvNoCC.mkDerivation {
    pname = "blueos-frontend-node-modules";
    inherit version src;

    impureEnvVars = lib.fetchers.proxyImpureEnvVars;

    nativeBuildInputs = [
      bun
      writableTmpDirAsHomeHook
    ];

    dontConfigure = true;

    buildPhase = ''
      runHook preBuild

      cd core/frontend
      export BUN_INSTALL_CACHE_DIR=$(mktemp -d)
      bun install \
        --cpu='*' \
        --os='*' \
        --frozen-lockfile \
        --ignore-scripts \
        --no-progress

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/core/frontend
      find . -type d -name node_modules -exec cp -R --parents {} $out/core/frontend \;

      runHook postInstall
    '';

    dontFixup = true;

    outputHash = "sha256-fjXSigFFtNKtoAVhtlNZVOX7Aioq67VIJDNgU3PxhaA=";
    outputHashAlgo = "sha256";
    outputHashMode = "recursive";
  };
in
stdenvNoCC.mkDerivation {
  pname = "blueos-frontend";
  inherit version src;

  nativeBuildInputs = [
    bun
    nodejs
    writableTmpDirAsHomeHook
  ];

  patches = [ ./podman-image-names.patch ];

  postPatch = ''
    ${submoduleCopy}
  '';

  configurePhase = ''
    runHook preConfigure

    cp -R ${nodeModules}/core/frontend/node_modules core/frontend/node_modules
    patchShebangs core/frontend/node_modules

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    # Vite reads VITE_* from the environment, and App.vue parses this as a git
    # describe string to build a GitHub link: the `tags/` prefix and the `-g`
    # hash are both meaningful to convertGitDescribeToUrl, so neither can be
    # dropped. The frontend is baked at build time, so this cannot be set at
    # runtime like the backend's GIT_DESCRIBE_TAGS.
    export VITE_APP_GIT_DESCRIBE="tags/${version}-0-g${builtins.substring 0 7 rev}"

    pushd core/frontend
    bun run build
    popd

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share
    cp -R core/frontend/dist $out/share/blueos-frontend

    runHook postInstall
  '';
}
