{
  lib,
  bun,
  blueos-source,
  nodejs,
  stdenvNoCC,
  writableTmpDirAsHomeHook,
}:
let
  inherit (blueos-source)
    version
    src
    rev
    date
    ;

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

    outputHash = "sha256-nyVPPdInd3ZKkelrmfXQ/J9wL9kncbO66w9JIXvMDSI=";
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

  patches = [ ./upstream-pr-4698.patch ];

  configurePhase = ''
    runHook preConfigure

    cp -R ${nodeModules}/core/frontend/node_modules core/frontend/node_modules
    patchShebangs core/frontend/node_modules

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    # Parsed by App.vue as a git describe string. No `tags/` prefix because this
    # is not a tagged build: the link then goes to the commit. The `-g` hash
    # keeps the shape main.ts checks before enabling Sentry.
    export VITE_APP_GIT_DESCRIBE="${version}-0-g${builtins.substring 0 7 rev}"

    # Pinned rather than read from the clock: a wall-clock value would make
    # every build a different store path.
    export VITE_BUILD_DATE="${date}"

    # Selects the generation-based version chooser.
    export VITE_BLUEOS_UPDATES=nixos

    # Upstream's Dockerfile raises this for the same reason: the bundle
    # otherwise dies with "JavaScript heap out of memory".
    export NODE_OPTIONS=--max-old-space-size=8192

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
