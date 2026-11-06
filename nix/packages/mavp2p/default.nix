{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:
buildGoModule (finalAttrs: {
  pname = "mavp2p";
  version = "1.1.1";

  src = fetchFromGitHub {
    owner = "bluenviron";
    repo = "mavp2p";
    tag = "v${finalAttrs.version}";
    hash = "sha256-F6EeBvMeJZZmbtukm5PtgQNrkH7iS90906xzGBSSsOc=";
  };

  vendorHash = "sha256-xeM7wwpVaATdBvwd5L1W9c8/oT8ro8VDSdnzDKytU18=";

  subPackages = [ "." ];

  meta = {
    description = "Flexible and efficient Mavlink router";
    homepage = "https://github.com/bluenviron/mavp2p";
    license = lib.licenses.mit;
    mainProgram = "mavp2p";
    platforms = lib.platforms.unix;
  };
})
