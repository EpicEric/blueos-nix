# Shared base for a BlueOS SD card image on a Raspberry Pi.
#
# Boot goes through the vendor firmware into U-Boot, which reads extlinux.conf
# from the generic-extlinux-compatible loader. That is what gives the image a
# generation menu; the firmware's own direct-kernel path has none.
{
  config,
  lib,
  pkgs,
  blueos,
  ubootPackage,
  sdImageModule,
  ...
}:
let
  inherit (lib) mkDefault mkForce;

  install = "${blueos.passthru.src}/install";

  # BlueOS ships these overlays as source and compiles them on the board. The
  # firmware install script only stages overlays already in the firmware
  # package, so they have to be built here instead.
  firmware = pkgs.runCommand "raspberrypifw-navigator" { nativeBuildInputs = [ pkgs.dtc ]; } ''
    cp -r ${pkgs.raspberrypifw} $out
    chmod -R u+w $out
    dtc -@ -Hepapr -I dts -O dtb \
      -o $out/share/raspberrypi/boot/overlays/spi0-led.dtbo \
      ${install}/overlays/spi0-led.dts
    dtc -@ -Hepapr -I dts -O dtb \
      -o $out/share/raspberrypi/boot/overlays/navigator-eeprom.dtbo \
      ${install}/overlays/navigator-eeprom.dts
  '';
in
{
  imports = [ sdImageModule ];

  hardware.raspberry-pi.firmware = {
    package = mkDefault firmware;
    # Loaded by the GPU firmware before U-Boot, which then keeps the device tree
    # the firmware built from config.txt.
    uboot.enable = mkDefault true;
    # Bootcount support, which the stock U-Boot build lacks, so that a
    # generation that never reaches userspace can be abandoned automatically.
    uboot.package = mkDefault ubootPackage;
  };

  # U-Boot keeps its boot counter here, and the rollback timer has to delete it
  # to confirm a generation, so the partition cannot stay noauto as in the base
  # sd-image module. nofail is kept: a corrupt firmware partition must still
  # leave a bootable system.
  fileSystems."/boot/firmware".options = mkForce [ "nofail" ];

  sdImage = {
    populateRootCommands = ''
      mkdir -p ./files/boot
      ${config.boot.loader.generic-extlinux-compatible.populateCmd} -c ${config.system.build.toplevel} -d ./files/boot
    '';
    compressImage = mkDefault true;
    firmwareSize = mkDefault 512;
  };

  # The default name is derived from system.nixos.label, which is the same for
  # every board: both images would be called the same and only one would survive
  # the upload to a release. The board is what tells them apart.
  image.baseName = mkDefault "blueos-${config.services.blueos.board}-${config.services.blueos.gitDescribe}";

  # The base profile pulls in every filesystem and its repair tools, and zfs
  # alone drags a Python in. A BlueOS device only needs these two.
  boot.supportedFilesystems = mkForce [
    "vfat"
    "ext4"
  ];
  boot.zfs.forceImportRoot = mkDefault false;

  # The default initrd module list includes Rockchip drivers that the Raspberry
  # Pi vendor kernel does not build.
  boot.initrd.allowMissingModules = mkDefault true;

  # BlueOS sizes its dphys-swapfile to 1GB when the card has room. Without a
  # swapfile the image has none, and the services get OOM killed instead.
  swapDevices = [
    {
      device = "/var/swapfile";
      size = 1024;
      priority = 10;
    }
  ];

  services.blueos = {
    enable = mkDefault true;
    package = mkDefault blueos;
    rollback.enable = mkDefault true;
  };

  documentation.enable = mkDefault false;

  system.stateVersion = "25.11";
}
