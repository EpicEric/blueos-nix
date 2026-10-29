# Raspberry Pi 4 / CM4 with a Navigator hat, mirroring install/boards/bcm_27xx.sh.
{
  lib,
  ...
}:
let
  inherit (lib) mkDefault;
in
{
  imports = [ ../common.nix ];

  # dtparam lines render before any overlay, which is what the board wants: a
  # dtparam after a dtoverlay configures that overlay instead of the board.
  hardware.raspberry-pi.configtxt = {
    settings.pi4 = {
      dtparam = [
        "i2c_vc=on"
        "i2c_arm_baudrate=1000000"
        "spi=on"
      ];
      enable_uart = mkDefault true;
      gpio = mkDefault [
        "11,24,25=op,pu,dh"
        "37=op,pd,dl"
      ];
    };

    # The Navigators expose four UARTs and three i2c buses. i2c6 keeps its
    # default pins, so only the baudrate differs.
    deviceTreeOverlays.pi4 = [
      { uart1 = { }; }
      { uart3 = { }; }
      { uart4 = { }; }
      { uart5 = { }; }
      { i2c1 = { }; }
      {
        i2c4 = {
          pins_6_7 = true;
          baudrate = 1000000;
        };
      }
      { i2c6.baudrate = 400000; }
      { spi0-led = { }; }
      { spi1-3cs = { }; }
      { dwc2.dr_mode = "otg"; }
    ];
  };

  # otg_mode is the CM4 default from nixos-hardware, but it claims the USB
  # controller that the dwc2 overlay needs for gadget mode.
  hardware.raspberry-pi.configtxt.settings.cm4.otg_mode = lib.mkForce null;

  hardware.i2c.enable = mkDefault true;

  boot.kernelModules = [
    "i2c-dev"
    "i2c-bcm2835"
    "bcm2835-v4l2"
    "dwc2"
    "g_ether"
    "slcan"
  ];
}
