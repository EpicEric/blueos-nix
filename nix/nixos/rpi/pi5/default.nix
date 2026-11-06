# Raspberry Pi 5 with a Navigator hat, mirroring install/boards/bcm_2712.sh.
{
  lib,
  ...
}:
let
  inherit (lib) mkDefault;
in
{
  imports = [ ../common.nix ];

  hardware.raspberry-pi.configtxt = {
    settings.pi5 = {
      dtparam = [
        "i2c_arm=on"
        "spi=on"
      ];
      # nixos-hardware turns this off because the Pi 5 mini UART can feed ghost
      # input into U-Boot. BlueOS needs the primary UART for the Navigator's
      # port C, and its own board script enables it too, so it wins here.
      enable_uart = lib.mkForce true;
      gpio = mkDefault [
        "11,24,25=op,pu,dh"
        "37=op,pd,dl"
      ];
    };

    # The Pi 5 exposes its UARTs through different overlays than the Pi 4, and
    # has one hardware i2c (3) plus a software one on GPIOs 22/23 for bus 6.
    deviceTreeOverlays.pi5 = [
      { uart0-pi5 = { }; }
      { uart2-pi5 = { }; }
      { uart3-pi5 = { }; }
      { uart4-pi5 = { }; }
      { i2c1 = { }; }
      { i2c3-pi5.baudrate = 400000; }
      {
        i2c-gpio = {
          i2c_gpio_sda = 22;
          i2c_gpio_scl = 23;
          bus = 6;
          i2c_gpio_delay_us = 0;
        };
      }
      { spi0-led = { }; }
      { spi1-3cs = { }; }
      { dwc2.dr_mode = "otg"; }
    ];
  };

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
