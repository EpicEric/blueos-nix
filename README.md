# blueos-nix

NixOS support for BlueOS on Raspberry Pis 4 and 5.

> [!Note]
> LLM disclaimer: This repo includes major contributions from large language models.

## What this tracks

`nix/packages/blueos-source` pins one specific commit of
[BlueRobotics/BlueOS](https://github.com/BlueRobotics/BlueOS), never a branch.
That commit is the only place the BlueOS version comes from: `blueos-core`,
`blueos-frontend` and the image all read it, so the version they report cannot
drift from the code they contain.

Pinning a commit rather than a branch is what keeps `nix build` reproducible: a
branch ref would make the result depend on when the build ran, and the source
hash would stop meaning anything. Advancing the pin is therefore a deliberate
bump, done by hand and reviewed, rather than something that happens on its own.

The pin currently sits between releases, so the version is a literal
(`1.5.0-dev`) instead of something derived from a tag, and the channel is
`dev`. Two consequences worth knowing:

- BlueOS reports `1.5.0-dev-0-g<rev>`. The version chooser lists local
  generations, which are distinguished by their store path and revision.
- The release manifest is a different matter: `publish` in the CI workflow keys
  entries on `(board, version)` and keeps only the newest, so two tagged
  releases built from different commits but the same `1.5.0-dev` replace each
  other rather than sitting side by side. That is correct for a rebuild of one
  version, but it means a dev build is not a durable release: bump `version`
  before tagging if the previous one should stay downloadable.
- Sentry stays off. `commonwealth/utils/sentry_config.py` only enables it when
  the describe string matches `<x.y.z>-<commits>-g<hash>`, and the `-dev`
  suffix fails that check. That is intended: crashes in a dev build are not
  crashes of a release that exists.

When the pin moves to a release commit, set `version` and `channel` to match
that release and drop the `-dev` suffix. Sentry then turns itself on, and the
frontend badge links the release page instead of the commit.

## Building an image

Both configurations are `aarch64-linux` systems, so building one needs either
an ARM host or `boot.binfmt.emulatedSystems` on an x86_64 machine. CI runs on
`ubuntu-24.04-arm` and builds them natively. There is no cross-compiled
variant: one existed until it was removed, and it is recoverable from `b3722dc`
if a slow x86_64 build ever becomes a problem again.

## Bumping the pin

1. Pick the commit. It needs the four frontend submodules to be resolvable,
   which is checked in step 5.

   ```fish
   git ls-remote https://github.com/BlueRobotics/BlueOS <ref>
   ```

2. Read its date, which becomes the build date shown in the UI.

   ```fish
   curl -s https://api.github.com/repos/BlueRobotics/BlueOS/commits/<rev> \
     | jq -r '.commit.committer.date'
   ```

3. Hash it, then convert that to the SRI form the package uses.

   ```fish
   set h (nix-prefetch-url --unpack \
     https://github.com/BlueRobotics/BlueOS/archive/<rev>.tar.gz | tail -1)
   nix hash convert --hash-algo sha256 --from nix32 --to sri $h
   ```

4. Update `nix/packages/blueos-source/default.nix`: `rev`, `hash`, and `date`.
   Leave `version` and `channel` alone unless the upstream release line moved.

5. Check the frontend submodules. They are fetched individually because the
   GitHub archive carries no submodule content, and their revisions are
   recorded in `.gitmodules` at the pinned commit.

   ```fish
   nix eval --raw .#blueos-source.src.outPath | xargs -I{} \
     git -C {} config --get-regexp '^submodule\..*\.url'
   ```

   If a revision differs from the one in `nix/packages/blueos-frontend`, update
   that file too, and recompute its hashes.

6. Rebuild. `blueos-frontend` needs a new `nodeModules.outputHash` whenever
   `bun.lockb` changed: set it to `lib.fakeHash`, build once, and copy the
   reported hash back.

   ```fish
   nix build .#blueos-frontend .#blueos-core
   ```

7. Triage the patches (see below), then let CI build the images.

## Patch policy

Upstream is a container image: it installs services into `/home/pi`, runs them
under `tmux`, and derives the version from a Docker tag. This repo runs the same
services as systemd units. The patches bridge that gap, and a bump is mostly
the work of re-checking them.

Every patch has to fall into exactly one of these buckets:

- **Delete on sight.** The patch was sent upstream and merged. Delete it in the
  same commit that moves the pin, never "keep it in case".
  `git apply --check -p1` is not a reliable signal here: three of the patches
  deleted in the last bump still applied cleanly while being entirely obsolete,
  because they landed on unrelated code.
- **Upstream then drop.** The fix belongs in BlueOS too. Open a PR, and carry
  the patch only until it merges, with the PR link in the patch header so the
  next bump knows what to look for.
- **Never upstream.** The change is wrong for the container image. Each of
  these needs a comment in the patch itself saying so and why, so it does not
  get proposed again.
- **Permanently carried.** A feature this repo needs that upstream will not
  take, or has not taken yet.

The patches currently carried:

| Patch                                          | Bucket              | Why                                                                                                                                                                                                                                                                                                   |
| ---------------------------------------------- | ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `blueos-core/cable-guy-dhcpcd.patch`           | Never upstream      | A `dhcpcd` daemon already owns the interface on Bookworm and Bullseye; the one-shot client would regress the inherited `DHCPCD` handler.                                                                                                                                                              |
| `blueos-core/helper-nixos-factory-mode.patch`  | Never upstream      | Skips the factory-mode probe, which asks the container version chooser for a `factory` tag. Generations have no such tag, so the probe only ever 404s here.                                                                                                                                           |
| `blueos-core/helper-nginx-paths.patch`         | Permanently carried | Points helper at this repo's nginx pid file, extension directory and config. Upstream's paths are container-specific.                                                                                                                                                                                 |
| `blueos-frontend/systemid-nixos-restart.patch` | Upstream then drop  | Restarts the core through the backend-aware helper. Belongs in PR 4698, which patches the same call in `PowerMenu.vue` but misses `SystemId.vue`; fold it in if the PR is updated.                                                                                                                    |
| `blueos-frontend/upstream-pr-4698.patch`       | Upstream then drop  | The generation-based version chooser, gated on `VITE_BLUEOS_UPDATES === 'nixos'`. Replaces a 3,000-line local patch that conflicted with the frontend rewrite. It is the PR's whole 13-commit range as one diff against the pin, ttag fixes included, so it needs regenerating whenever the PR moves. |

## Known gaps

- **Log rotation.** Upstream removed the `log_zipper` service without a
  replacement. `/var/logs/blueos` now grows until `nix.gc` removes an old
  generation. Worth revisiting if upstream adds rotation back.
- **Navigator EEPROM.** The EEPROM endpoints read
  `/sys/bus/i2c/devices/0-0050/eeprom`, which only exists when the
  `navigator-eeprom` device tree overlay is loaded. The Pi 4 image loads it;
  the Pi 5 board script does not, so those endpoints report `EEPROM_NOT_FOUND`
  there.
