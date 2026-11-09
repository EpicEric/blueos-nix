# The single place the BlueOS version is pinned. Both blueos-core and
# blueos-frontend build from this source, so the version they report cannot
# drift from the code they actually contain.
#
# `rev` is a specific commit, not a branch ref: a branch would make `nix build`
# depend on when it ran, and the hash below would stop meaning anything. Moving
# the pin is a deliberate bump, documented in the README.
{
  fetchFromGitHub,
}:
rec {
  # A literal rather than a value derived from a tag, so the version is
  # readable from the closure instead of only from git. The `-dev` suffix is
  # deliberate, see the `channel` comment below.
  version = "1.5.0-dev";

  # Pinned by commit: a tag ref is not an identity, and the version chooser
  # needs something that distinguishes two builds of the same tag. The hash
  # below is the commit's own tree.
  rev = "baf03706fb6f1277aa3e9f563ee7bf2a76f62cd7";

  # BlueOS reports its channel to Sentry and to the version chooser. `dev`
  # both distinguishes these builds from released ones and keeps them out of
  # Sentry, which only accepts a `<x.y.z>-<commits>-g<hash>` describe string.
  channel = "dev";

  # The pinned commit's date, in the format the frontend shows as "Build:".
  # `VITE_BUILD_DATE` is baked into the bundle, so it has to be a fixed value:
  # reading the wall clock makes every build a different store path, which
  # defeats the binary cache. Update this whenever `rev` moves.
  date = "2026-11-09";

  src = fetchFromGitHub {
    owner = "BlueRobotics";
    repo = "BlueOS";
    inherit rev;
    hash = "sha256-ZvzQjMu4xvjE4gg6SVixz8McEJPWMmlmE1vDiJ5y9VI=";
  };
}
