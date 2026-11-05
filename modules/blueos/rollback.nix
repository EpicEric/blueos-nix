# Automatic rollback for a BlueOS SD card.
#
# Two layers, because they cover different failures:
#
#   - U-Boot abandons a generation that never reaches userspace. The firmware
#     config points U-Boot at a bootcount file on the FAT partition; three
#     failed attempts make it run altbootcmd, which boots good.conf instead of
#     the extlinux menu. Nothing in the new generation has to work for this,
#     which is the case that actually bricks a card.
#   - A timer rolls back a generation that boots but is not healthy, or that
#     never confirms. This is what a bad service or network configuration needs,
#     since the bootloader cannot tell.
#
# Arming happens in a pre-switch check rather than an activation script:
# switch-to-configuration exits before activating for `boot`, so an activation
# script would miss every update that needs a reboot.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.blueos.rollback;

  stateDir = "/var/lib/blueos/updates";
  stateFile = "${stateDir}/state.json";
  firmwareDir = config.hardware.raspberry-pi.firmware.path;
  bootcountFile = "${firmwareDir}/bootcount";

  profile = "/nix/var/nix/profiles/system";
  gcroot = "/nix/var/nix/gcroots/blueos/known-good";
  goodConf = "/boot/extlinux/good.conf";

  nix = config.nix.package.out;

  # Taken from the configuration rather than matched by name: the BlueOS units
  # are called ardupilot-manager, helper and so on, so no glob identifies them.
  blueosUnits = lib.attrNames (
    lib.filterAttrs (_: unit: lib.elem "blueos.target" (unit.wantedBy or [ ])) config.systemd.services
  );

  # The format is fixed by drivers/bootcount/bootcount_fs.c: magic, version,
  # count, upgrade flag. Writing it directly arms the fallback for the next
  # boot; deleting it disarms, since a missing file reads as zero.
  arm = pkgs.writeShellScript "blueos-rollback-arm" ''
    set -eu
    toplevel=$(readlink -f "$1")
    action=$2

    # Only switch and boot change what the next boot runs. `test` activates
    # without making the generation the default, so rolling it back would
    # discard a system the operator did not ask to keep.
    case "$action" in
      switch|boot) ;;
      *) exit 0 ;;
    esac

    # nixos-rebuild sets the profile before calling switch-to-configuration, so
    # the profile already names this generation here. The running system is what
    # says whether anything actually changed.
    if [ "$toplevel" = "$(readlink -f /run/current-system)" ]; then
      exit 0
    fi

    mkdir -p ${stateDir}
    printf '{"pending":"%s","mode":"%s"}\n' "$toplevel" "$action" > ${stateFile}.tmp
    mv ${stateFile}.tmp ${stateFile}

    # The deadline is a boot timer, so it has already fired if this update came
    # long after boot. Restarting it gives the new generation the full window
    # either way; under `boot` the reboot resets it anyway.
    ${config.systemd.package}/bin/systemctl restart blueos-rollback.timer 2>/dev/null || true

    # The boot unit ran before this update existed, so without something else
    # the new generation would stay unconfirmed until the deadline and only then
    # be judged. This cannot be judged here: these checks run before the switch,
    # so the profile already names the new generation while the old one is still
    # what is running, and confirming now would record a build that never booted.
    # A detached watcher waits for the switch to actually land instead.
    ${config.systemd.package}/bin/systemctl stop blueos-confirm-after-switch.service 2>/dev/null || true
    ${config.systemd.package}/bin/systemd-run \
      --quiet --no-block --collect --system \
      --unit=blueos-confirm-after-switch \
      --service-type=oneshot \
      --description="Confirm the generation an update just switched to" \
      --setenv=PATH="$PATH" \
      ${confirmAfterSwitch} "$toplevel" 2>/dev/null || true

    # Never arm the boot fallback without a generation to fall back to:
    # altbootcmd boots good.conf, and a missing file leaves the board at the
    # U-Boot prompt instead of starting a system. The runtime timer still
    # protects the update, since state.json is already written.
    if [ ! -s ${goodConf} ]; then
      echo "no known-good generation yet, leaving the bootcount fallback disarmed" >&2
      exit 0
    fi

    if [ -d ${firmwareDir} ]; then
      printf '\275\001\000\001' > ${bootcountFile}
      sync ${bootcountFile} 2>/dev/null || sync
    fi
  '';

  # One check, called by the boot unit and again by the rollback deadline, so
  # the two can never disagree about what "healthy" means.
  healthCheckScript = pkgs.writeShellScript "blueos-health-check" ''
    set -eu

    failed=0
    for unit in ${lib.concatMapStringsSep " " (u: "${u}.service") blueosUnits}; do
      case "$(${config.systemd.package}/bin/systemctl is-failed "$unit" || true)" in
        failed) echo "$unit failed to start" >&2; failed=1 ;;
      esac
    done
    [ "$failed" -eq 0 ]

    # The core is only up when nginx serves the status endpoint it proxies.
    ${pkgs.curl}/bin/curl --fail --silent --max-time 30 http://127.0.0.1/status > /dev/null

    ${cfg.healthCheck}
  '';

  # A generation only counts as known-good once its services came up, so this
  # is a separate unit from the update daemon: a daemon that is itself broken
  # cannot be the one to report that the system is fine.
  confirm = pkgs.writeShellScript "blueos-rollback-confirm" ''
    set -eu
    toplevel=$(readlink -f ${profile})

    rm -f ${bootcountFile}
    sync

    mkdir -p "$(dirname ${gcroot})"
    ln -sfn "$toplevel" ${gcroot}

    # altbootcmd boots this directly, so it bypasses the extlinux menu and
    # cannot be confused by a generation that was written after it. Paths are
    # absolute: a relative one would be resolved against /boot/extlinux.
    mkdir -p "$(dirname ${goodConf})"
    {
      printf 'DEFAULT blueos-good\n'
      printf 'LABEL blueos-good\n'
      printf '  LINUX %s/kernel\n' "$toplevel"
      printf '  INITRD %s/initrd\n' "$toplevel"
      printf '  APPEND init=%s/init %s\n' "$toplevel" "$(cat "$toplevel/kernel-params")"
    } > ${goodConf}.tmp
    mv ${goodConf}.tmp ${goodConf}
    sync

    printf '{"knownGood":"%s"}\n' "$toplevel" > ${stateFile}.tmp
    mv ${stateFile}.tmp ${stateFile}
  '';

  # Judges a generation that an update just switched to, without waiting for the
  # deadline. The pre-switch check cannot do this itself: it runs before the
  # switch, when the profile already names the new generation but the old one is
  # still running, so judging there would confirm a build that never booted.
  #
  # The generation is passed in and compared against what is actually running, so
  # a switch that never lands is left to the rollback timer rather than confirmed.
  confirmAfterSwitch = pkgs.writeShellScript "blueos-confirm-after-switch" ''
    set -eu
    expected=$1

    # The switch stops this unit if it is still waiting, and restarts it under
    # the same name; either way the delay belongs to this unit's own lifetime.
    deadline=$(( $(date +%s) + ${toString cfg.settleDelaySeconds} ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
      sleep 1
    done

    running=$(readlink -f /run/current-system)
    if [ "$running" != "$expected" ]; then
      echo "still running $running, not confirming $expected" >&2
      exit 0
    fi

    # A reboot is owed, so this generation has not run yet and cannot be judged.
    case "$(readlink -f ${profile})" in
      "$running") ;;
      *) echo "a reboot is owed before $expected can be judged" >&2; exit 0 ;;
    esac

    if ${healthCheckScript}; then
      echo "the generation the update switched to is healthy, confirming it"
      ${confirm}
    else
      echo "the generation the update switched to is not healthy; leaving it to the deadline" >&2
    fi
  '';

  rollback = pkgs.writeShellScript "blueos-rollback" ''
    set -eu

    # The deadline runs at boot whether or not an update is pending, so the state
    # file decides: only a generation that was armed and never confirmed is a
    # rollback. Anything else means this system has been fine all along, which is
    # the ordinary case and must not fail the unit.
    if ! grep -q '"pending"' ${stateFile} 2>/dev/null; then
      echo "no update pending, nothing to roll back"
      exit 0
    fi

    # The known-good pointer is a symlink to a generation directory, so readlink
    # is what yields the store path; cat would print the directory's contents.
    known_good=$(readlink -f ${gcroot} 2>/dev/null || true)
    if [ -z "$known_good" ] || [ ! -e "$known_good" ]; then
      echo "update pending but no known-good generation recorded, leaving the system alone" >&2
      exit 1
    fi

    # Re-checked here rather than trusted from the unit: a healthy generation
    # whose confirmation never ran would otherwise be rolled back needlessly.
    if ${healthCheckScript}; then
      echo "the running generation is healthy, confirming it"
      ${confirm}
      exit 0
    fi

    # Already on the target and still unhealthy: rolling back again would loop
    # forever. Leave it for the operator instead.
    if [ "$(readlink -f ${profile})" = "$known_good" ]; then
      echo "the known-good generation is itself unhealthy, refusing to loop" >&2
      exit 1
    fi

    echo "rolling back to $known_good"
    ${nix}/bin/nix-env --profile ${profile} --set "$known_good"
    # This runs the pre-switch check of the target generation, which arms the
    # rollback again. Undo that: the fallback has already been used, and a
    # generation that fails to boot still needs the operator.
    "$known_good/bin/switch-to-configuration" boot

    rm -f ${bootcountFile}
    printf '{"knownGood":"%s","rolledBackFrom":"%s"}\n' "$known_good" \
      "$(readlink -f /run/current-system)" > ${stateFile}.tmp
    mv ${stateFile}.tmp ${stateFile}
    sync

    ${config.systemd.package}/bin/systemctl reboot
  '';
in
{
  options.services.blueos.rollback = {
    enable = lib.mkEnableOption "automatic rollback of a failed BlueOS update";

    timeout = lib.mkOption {
      type = lib.types.str;
      default = "10min";
      example = "30min";
      description = ''
        How long a freshly activated generation has to confirm itself before it
        is rolled back. Services come up in seconds; the margin is for the
        vehicle to reach the network, which is when a user can intervene.
      '';
    };

    settleDelaySeconds = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 30;
      description = ''
        How long to wait before judging a generation, so that services that
        restart a few times on startup are not counted as failed.
      '';
    };

    settleDelay = lib.mkOption {
      type = lib.types.str;
      internal = true;
      readOnly = true;
      default = "${toString cfg.settleDelaySeconds}s";
      defaultText = lib.literalMD "`settleDelaySeconds`, in systemd's time-span syntax";
      description = "`settleDelaySeconds` in the form systemd's `ExecStartPre` accepts.";
    };

    healthCheck = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        Extra shell commands run before a generation is confirmed. A non-zero
        exit treats the generation as failed.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # The check text is inlined into a generated script whose $1 and $2 are the
    # new toplevel and the action, so they have to be forwarded: a bare path
    # would run the script as a child with no arguments at all.
    system.preSwitchChecks.blueos-rollback-arm = "${arm} \"$1\" \"$2\"";

    systemd.services.blueos-boot-health = {
      description = "Confirm the running BlueOS generation";
      wantedBy = [ "multi-user.target" ];
      # The check asks the services whether they came up, so it has to run after
      # they were started rather than racing them.
      after = [
        "blueos.target"
        "nginx.service"
      ];
      wants = [ "blueos.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "blueos-boot-health" ''
          set -eu
          sleep ${cfg.settleDelay}
          ${healthCheckScript}
          ${confirm}
        '';
      };
    };

    systemd.services.blueos-rollback = {
      description = "Roll back to the last known-good BlueOS generation";
      after = [ "blueos-boot-health.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = rollback;
      };
    };

    # Wanted at boot so a generation that hangs has a deadline too, rather than
    # only one that failed a health check.
    systemd.timers.blueos-rollback = {
      description = "Deadline for the running BlueOS generation to confirm";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # Relative to activation rather than to boot: the timer is active from
        # boot, so this covers a generation left pending by a previous boot, and
        # arming restarts it, which gives the new generation the full window.
        # OnBootSec cannot be combined with it: with both set, systemd elapses at
        # whichever comes first, so a restart after the boot offset had passed
        # would fire the rollback immediately.
        OnActiveSec = cfg.timeout;
        Unit = "blueos-rollback.service";
      };
    };

    # A rollback target is a store path that extlinux and the bootcount fallback
    # both point at, so it has to survive garbage collection. It is kept through
    # the gcroots/blueos symlink above; gc-keep-derivations would pin an entire
    # build closure for a target that only needs to boot.

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0755 root root -"
      "d /nix/var/nix/gcroots/blueos 0755 root root -"
      "d /boot/extlinux 0755 root root -"
    ];
  };
}
