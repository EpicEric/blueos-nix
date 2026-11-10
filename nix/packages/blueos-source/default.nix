# The single pin for the BlueOS version, shared by blueos-core and
# blueos-frontend. Bumping it is documented in the README.
{
  fetchFromGitHub,
}:
rec {
  # A literal so the version is readable from the closure, not only from git.
  # The `-dev` suffix is deliberate, see `channel` below.
  version = "1.5.0-dev";

  # Pinned by commit, not tag: the version chooser needs something that
  # distinguishes two builds of the same tag.
  rev = "baf03706fb6f1277aa3e9f563ee7bf2a76f62cd7";

  # Reported to Sentry and to the version chooser. `dev` keeps these builds out
  # of Sentry, which only accepts a `<x.y.z>-<commits>-g<hash>` describe string.
  # Available options:
  # - stable
  # - beta
  # - dev
  channel = "dev";

  # The pinned commit's date, in the format the frontend shows as "Build:".
  # Fixed rather than read from the clock: the wall clock would make every build
  # a different store path. Update whenever `rev` moves.
  date = "2026-11-09";

  src = fetchFromGitHub {
    owner = "BlueRobotics";
    repo = "BlueOS";
    inherit rev;
    hash = "sha256-ZvzQjMu4xvjE4gg6SVixz8McEJPWMmlmE1vDiJ5y9VI=";
  };
}
