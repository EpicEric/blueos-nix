# The single place the BlueOS version is pinned. Both blueos-core and
# blueos-frontend build from this source, so the version they report cannot
# drift from the code they actually contain.
{
  fetchFromGitHub,
}:
rec {
  version = "1.4.7";
  # Pinned by commit rather than tag: a tag ref is not an identity, and the
  # version chooser needs something that distinguishes two builds of the same
  # tag. The hash below is the tag's own tree, so it did not change.
  rev = "2b918ed7ea253f0e5ad2f1d27ecff7c4b437a106";

  channel = "stable";

  src = fetchFromGitHub {
    owner = "BlueRobotics";
    repo = "BlueOS";
    inherit rev;
    hash = "sha256-gXbPV7CC0yIaR2JaLRy6rDVHzKstZzsjViU2jQ5xly4=";
  };
}
