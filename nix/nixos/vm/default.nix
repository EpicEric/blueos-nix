# A BlueOS system for a QEMU virtual machine, used by the end-to-end tests.
#
# The artifact is a self-contained EFI disk: its own Nix store, its own system
# profile, a real bootloader. Not a VM that borrows the host's store, for two
# reasons. The wifi lab needs a machine whose state is entirely its own -- it
# stands up access points, moves radios between network namespaces and lets
# BlueOS reconfigure interfaces, and none of that should reach the host. And a
# disk is portable: the tests can boot it, or hand it to someone else.
#
# `system.build.image` is that disk, built from nixpkgs' own disk-image module.
# The tests run QEMU themselves against it, because the wifi scenarios need to
# shape the machine -- extra radios, namespaces, a second QEMU to act as a
# neighbouring station -- which a fixed runner script cannot express.
#
# `virtualisation.vmVariant` below only exists so `nixos-rebuild build-vm` is
# usable for interactive work; it keeps the host-store default, which is faster
# and good enough for poking at the UI.
#
# Boot is UEFI with systemd-boot rather than BIOS, because aarch64 has no non-EFI
# GRUB target: EFI is what lets one configuration serve both architectures.
#
# What this target can and cannot exercise:
#
#   - Generations and updates can be tested against the disk. The guest owns
#     /nix/var/nix/profiles/system, so `blueos-updates` and
#     switch-to-configuration act on the guest rather than on the machine
#     running the tests.
#   - Rollback cannot, and is forced off below. It abandons a generation that
#     never reaches userspace through U-Boot's bootcount file on the Pi's
#     firmware partition, and falls back to an extlinux `good.conf`. A VM has no
#     U-Boot, no bootcount partition and no extlinux menu -- it boots systemd-boot
#     from the EFI system partition -- so there is nothing for the fallback to
#     drive. The runtime half is inapplicable for the same reason: rollback.nix
#     reads `hardware.raspberry-pi.firmware.path`, which does not exist off a Pi.
#     Both halves need a device, so rollback stays hardware-in-the-loop.
{
  config,
  lib,
  pkgs,
  modulesPath,
  blueos,
  ...
}:
let
  inherit (lib) mkDefault mkForce;

  arch = pkgs.stdenv.hostPlatform.qemuArch;

  # The radios mac80211_hwsim creates at load time. BlueOS drives wlan0; the
  # wifi tests move the rest into a network namespace of their own to act as
  # access points, and scan from the last one.
  radios = 6;
in
{
  imports = [
    "${modulesPath}/profiles/qemu-guest.nix"
    # Provides `system.build.image` and the `image.*` options. The runner comes
    # from `virtualisation.vmVariant`, so that the disk can be built on its own
    # without also building one.
    "${modulesPath}/virtualisation/disk-image.nix"
    ../../modules/blueos
  ];

  boot = {
    # `disk-image.nix` turns systemd-boot on from `image.efiSupport`. GRUB has to
    # be off: it would also claim `system.build.installBootLoader`, and that
    # option is `types.unique`.
    loader.grub.enable = mkForce false;

    kernelModules = [ "mac80211_hwsim" ];

    # The simulated radios are the point of the wifi tests. `channels=2` lets one
    # radio be an access point and a client at once, which is what makes the lab
    # fit inside a single guest.
    extraModprobeConfig = ''
      options mac80211_hwsim radios=${toString radios} channels=2
      options cfg80211 ieee80211_regdom=US
    '';

    # ext4 is the root and vfat is the EFI system partition the disk carries.
    # The other filesystems and their repair tools are a large part of a profile
    # this machine does not need.
    supportedFilesystems = mkForce [
      "ext4"
      "vfat"
    ];
  };

  # The label `make-disk-image.nix` writes, which is how the initrd finds root:
  # the device name depends on the bus QEMU is told to use.
  fileSystems."/" = {
    label = "nixos";
    fsType = "ext4";
  };

  image = {
    # Stable name for the artifact, instead of one carrying the nixpkgs version.
    baseName = mkDefault "blueos-${arch}";
    # Explicit rather than inherited: the `qemu` variant sets this to false, and
    # EFI is what makes aarch64 possible at all.
    efiSupport = mkDefault true;
  };

  # The disk carries its own store plus the BlueOS container images the tests
  # load into the guest, which the closure alone leaves no room for.
  virtualisation.diskSize = mkDefault 16384;

  services.blueos = {
    enable = mkDefault true;
    package = mkDefault blueos;
    board = mkDefault "blueos-vm";
    # No U-Boot bootcount partition and no extlinux menu to fall back through;
    # see the top of the file.
    rollback.enable = mkForce false;
    # These settings assume the Raspberry Pi vendor kernel and its device tree.
    raspberryPi.enable = mkForce false;
  };

  # The module leaves this empty so a device can set it from its own state. A VM
  # is reached by IP, so a stable name is more useful.
  networking.hostName = mkForce "blueos";

  # The tests reach the guest through forwarded ports, and the BlueOS services
  # reach each other directly; a per-port allowlist cannot cover either.
  networking.firewall.enable = mkForce false;

  documentation.enable = mkDefault false;

  # The wifi tests drive access points in the guest over SSH by running hostapd
  # directly, and inspect interfaces with `iw`. The module supplies dnsmasq and
  # iproute2 for BlueOS itself, but not these.
  environment.systemPackages = with pkgs; [ hostapd ];

  system.stateVersion = "26.11";

  # Only for interactive use through `nixos-rebuild build-vm`. The tests do not
  # use this runner, and it is left on the host's Nix store on purpose: faster to
  # start, and nothing here is testing the update path.
  virtualisation.vmVariant.virtualisation = {
    graphics = false;
    cores = 4;
    memorySize = 3072;
    forwardPorts = [
      {
        from = "host";
        host.port = 2222;
        guest.port = 22;
      }
      {
        from = "host";
        host.port = 8080;
        guest.port = 80;
      }
    ];
  };

  system.build = {
    # The same disk under the name the harness looks for, since `system.build.image`
    # carries a name derived from the nixpkgs version.
    qemuDiskImage = config.system.build.image;

    # Everything QEMU needs to boot the disk as one directory: the disk, the EFI
    # firmware for this architecture, a writable copy of its variable store, and
    # the network layout the tests expect. An EFI disk is not bootable on its
    # own -- `make-disk-image.nix` writes no NVRAM, so the machine has to be
    # handed firmware and variables separately, and those are per-architecture.
    qemuImage =
      let
        ovmf = pkgs.OVMF.fd;
      in
      pkgs.runCommand "blueos-${arch}-qemu-image" { } ''
        mkdir -p $out
        ln -s ${config.system.build.image}/${config.image.fileName} $out/disk.qcow2
        ln -s ${ovmf.firmware} $out/firmware.fd
        # A writable copy, since QEMU cannot open the read-only store path as its
        # variable store. Each run gets its own copy of this file.
        cp ${ovmf.variables} $out/vars.fd
        chmod 0644 $out/vars.fd

        # The wifi lab needs the radios to reach both the guest and a scanner,
        # and the tests reach the guest on these ports.
        cat > $out/README <<'EOF'
        Boot this with qemu-system-${arch}:

          -machine q35 (x86) or -machine virt (aarch64)
          -drive if=pflash,format=raw,readonly=on,file=firmware.fd
          -drive if=pflash,format=raw,file=vars.fd
          -drive file=disk.qcow2,if=virtio,format=qcow2
          -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22,hostfwd=tcp:127.0.0.1:8080-:80
          -device virtio-net-pci,netdev=n0
          -nographic

        Copy vars.fd per run; booting modifies it.
        EOF
      '';
  };
}
