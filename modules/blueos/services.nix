# One systemd unit per entry in core/start-blueos-core at BlueOS 1.4.7.
#
# The Python services are already wrapped by blueos-core: each $out/bin/<name>
# sets PYTHONPATH to the service directory and puts the ArduPilot scripts on
# PATH, so a unit only has to name the wrapper.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.blueos;
  inherit (lib) mkIf optionals optionalAttrs;

  blueos = cfg.package;
  logs = "/var/logs/blueos/services";

  # zenohd only searches next to its own binary and in the directories named
  # here, while the packaged plugins live in $out/lib.
  zenohConfig = pkgs.writeText "blueos-zenoh.json5" ''
    {
      plugins_loading: { enabled: true, search_dirs: ["${pkgs.zenoh}/lib"] },
      plugins: { rest: { http_port: 7117 } }
    }
  '';

  # mavlink-camera-manager is a foreign binary, so nothing wraps it with the
  # GStreamer plugin path.
  gstPluginPath = lib.makeSearchPathOutput "lib" "lib/gstreamer-1.0" (
    with pkgs.gst_all_1;
    [
      gstreamer
      gst-plugins-base
      gst-plugins-good
      gst-plugins-bad
      gst-plugins-ugly
      gst-libav
      gst-plugins-rs
      pkgs.libcamera
      pkgs.libnice
    ]
  );

  # The services look tool binaries up by name, the way the container does.
  toolPath = [
    cfg.packages.ardupilot-tools
    cfg.packages.bridges
    cfg.packages.machineid-cli
    cfg.packages.mavlink-router
    cfg.packages.mavlink-server
    cfg.packages.mavp2p
  ];

  python = name: args: lib.escapeShellArgs ([ "${blueos}/bin/${name}" ] ++ args);

  mkService =
    {
      name,
      exec,
      memoryMax ? null,
      nice ? 0,
      user ? "root",
      path ? [ ],
      after ? [ ],
      environment ? { },
      serviceConfig ? { },
      preStart ? "",
    }:
    {
      description = "BlueOS ${name}";
      wantedBy = [ "blueos.target" ];
      partOf = [ "blueos.target" ];
      after = [ "network.target" ] ++ after;
      restartTriggers = [ blueos ];
      # Units get coreutils only; the services shell out to host tools that
      # live in the system profile.
      path = [ "/run/current-system/sw" ] ++ toolPath ++ path;
      environment = {
        MAV_SYSTEM_ID = toString cfg.mavlink.systemId;
        MAV_COMPONENT_ID_ONBOARD_COMPUTER4 = toString cfg.mavlink.componentId;
        # Reported by commonwealth.utils.general.blueos_version(), which feeds
        # the helper heartbeat, the host log dumps and Sentry. environment.variables
        # only reaches PAM sessions, so units need it here.
        GIT_DESCRIBE_TAGS = cfg.gitDescribe;
        RUST_BACKTRACE = "1";
      }
      // environment;
      preStart = "mkdir -p ${logs}/${name}\n" + preStart;
      serviceConfig = {
        ExecStart = exec;
        Restart = "always";
        RestartSec = 1;
        Nice = nice;
        User = user;
        WorkingDirectory = "/";
      }
      // optionalAttrs (memoryMax != null) { MemoryMax = "${toString memoryMax}M"; }
      // serviceConfig;
    };
in
{
  config = mkIf cfg.enable {
    users.users.blueos = {
      isSystemUser = true;
      group = "blueos";
      extraGroups = [ "dialout" ];
    };
    users.groups.blueos = { };

    systemd.tmpfiles.rules = [
      # ardupilot_manager chmods the file before installing it, so it wants a
      # copy rather than a link into the store.
      "C+ /root/blueos-files/ardupilot-manager/default/ardupilot_navigator64 - - - - ${
        pkgs.fetchurl {
          url = "https://firmware.ardupilot.org/Sub/stable-4.5.3/navigator64/ardusub";
          hash = "sha256-mV5Rv5xo8TGnh+Csa4QJxryxPjcUyWKuSF23YJs85Hk=";
        }
      }"
    ]
    ++
      optionals cfg.raspberryPi.enable
        # ArduSub identifies the board from the soc node, which this kernel
        # names soc@107c000000, so a view with the expected name is mounted.
        [
          "C /run/blueos/device-tree - - - - /sys/firmware/devicetree/base"
          "L /run/blueos/device-tree/soc - - - - soc@107c000000"
        ];

    systemd.targets.blueos = {
      description = "BlueOS";
      wantedBy = [ "multi-user.target" ];
    };

    systemd.services = {
      # Extensions read these through the host root: major_tom opens
      # /host/etc/blueos/{hardware-uuid,uuid} at import time, and commonwealth's
      # local_*_identifier() reads them here. Upstream has both files created by
      # start-blueos-core and helper, which this system does not run.
      blueos-uuids = {
        description = "BlueOS hardware and software uuids";
        wantedBy = [ "blueos.target" ];
        before = [ "blueos.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ${cfg.packages.machineid-cli}/bin/machineid-cli \
            --key blueos --parts cpu-cores cpuid mac-address > /etc/blueos/hardware-uuid

          # Stable across boots and shared with the cloud, so it is written once
          # rather than regenerated like the hardware uuid.
          if [ ! -s /etc/blueos/uuid ]; then
            ${pkgs.util-linux}/bin/uuidgen | ${pkgs.coreutils}/bin/tr -d '-' > /etc/blueos/uuid
          fi
        '';
      };

      ardupilot-manager = mkService {
        name = "ardupilot_manager";
        nice = -19;
        exec = python "ardupilot_manager" [ ];
        # ArduSub binaries are glibc dynamic and downloaded at runtime; units do
        # not inherit the session variables nix-ld reads.
        environment = {
          inherit (config.environment.variables) NIX_LD NIX_LD_LIBRARY_PATH;
        };
        serviceConfig =
          optionalAttrs cfg.raspberryPi.enable {
            BindReadOnlyPaths = [ "/run/blueos/device-tree:/sys/firmware/devicetree/base" ];
          }
          // {
            # firmware flashing and MAVLink routing need the serial ports
            PrivateDevices = false;
            RestrictAddressFamilies = [ ];
          };
      };

      video = mkService {
        name = "mavlink-camera-manager";
        nice = -19;
        exec = ''
          ${cfg.packages.mavlink-camera-manager}/bin/mavlink-camera-manager \
            --default-settings BlueROVUDP \
            --mavlink tcpout:127.0.0.1:5777 \
            --mavlink-system-id ${toString cfg.mavlink.systemId} \
            --mavlink-camera-component-id-range=100-105 \
            --gst-feature-rank omxh264enc=0,v4l2h264enc=250,x264enc=260 \
            --log-path ${logs}/mavlink-camera-manager \
            --stun-server stun://stun.l.google.com:19302 \
            --enable-realtime-threads \
            --verbose
        '';
        environment.GST_PLUGIN_SYSTEM_PATH_1_0 = gstPluginPath;
        # the encoder and camera plugins are dlopened at runtime
        serviceConfig.PrivateDevices = false;
      };

      mavlink2rest = mkService {
        name = "mavlink2rest";
        exec = ''
          ${cfg.packages.mavlink2rest}/bin/mavlink2rest \
            --connect=udpout:127.0.0.1:14001 \
            --server [::]:6040 \
            --system-id ${toString cfg.mavlink.systemId} \
            --component-id ${toString cfg.mavlink.componentId}
        '';
      };

      cable-guy = mkService {
        name = "cable_guy";
        exec = python "cable_guy" [ ];
        # sets addresses and runs its own dhcpcd and dnsmasq
        serviceConfig = {
          PrivateDevices = false;
          RestrictAddressFamilies = [ ];
          CapabilityBoundingSet = [
            "CAP_NET_ADMIN"
            "CAP_NET_RAW"
            "CAP_NET_BIND_SERVICE"
          ];
        };
      };

      kraken = mkService {
        name = "kraken";
        nice = 19;
        exec = python "kraken" [ ];
        serviceConfig.SupplementaryGroups = [
          "docker"
          "podman"
        ];
      };

      wifi = mkService {
        name = "wifi";
        nice = 19;
        exec = python "wifi" [
          "--socket"
          "wlan0"
        ];
        serviceConfig = {
          RestrictAddressFamilies = [ ];
          # talks to the wpa_supplicant socket and to NetworkManager
          PrivateDevices = false;
        };
      };

      zenohd = mkService {
        name = "zenohd";
        exec = "${pkgs.zenoh}/bin/zenohd -c ${zenohConfig}";
      };

      beacon = mkService {
        name = "beacon";
        memoryMax = 250;
        exec = python "beacon" [ ];
        # announces itself over multicast DNS and UDP
        serviceConfig.RestrictAddressFamilies = [ ];
      };

      bridget = mkService {
        name = "bridget";
        nice = 19;
        user = "blueos";
        exec = python "bridget" [ ];
        serviceConfig.PrivateDevices = false;
      };

      commander = mkService {
        name = "commander";
        memoryMax = 250;
        exec = python "commander" [ ];
      };

      nmea-injector = mkService {
        name = "nmea_injector";
        memoryMax = 250;
        nice = 19;
        exec = python "nmea_injector" [ ];
      };

      helper = mkService {
        name = "helper";
        memoryMax = 250;
        exec = python "helper" [ ];
        # commonwealth reads the uuid while this module is imported
        after = [ "blueos-uuids.service" ];
        # reads the nginx config and reloads nginx through its pid file
        serviceConfig.ReadOnlyPaths = [ "/etc/blueos" ];
      };

      pardal = mkService {
        name = "pardal";
        memoryMax = 250;
        nice = 19;
        exec = python "pardal" [ ];
      };

      ping = mkService {
        name = "ping";
        nice = 19;
        user = "blueos";
        exec = python "ping" [ ];
        serviceConfig.PrivateDevices = false;
      };

      blueos-updates = mkService {
        name = "blueos-updates";
        memoryMax = 250;
        exec = "${cfg.packages.updates}/bin/blueos-updates";
        environment = {
          BLUEOS_BOARD = cfg.board;
          BLUEOS_UPDATES_ADDR = "127.0.0.1:8081";
        }
        // lib.optionalAttrs (cfg.updates.manifestUrl != null) {
          BLUEOS_UPDATES_MANIFEST = cfg.updates.manifestUrl;
        };
      };
      log-zipper = mkService {
        name = "log_zipper";
        memoryMax = 250;
        nice = 19;
        exec = python "log_zipper" [
          "/shortcuts/system_logs/**/*.log"
          "--max-age-minutes"
          "60"
        ];
      };

      bag-of-holding = mkService {
        name = "bag_of_holding";
        memoryMax = 250;
        exec = python "bag_of_holding" [ ];
      };

      linux2rest = mkService {
        name = "linux2rest";
        memoryMax = 250;
        exec = ''
          ${cfg.packages.linux2rest}/bin/linux2rest \
            --log-path ${logs}/linux2rest \
            --log-settings netstat=30,platform=10,serial-ports=10,system-cpu=10,system-disk=30,system-info=10,system-memory=10,system-network=10,system-process=60,system-temperature=10,system-unix-time-seconds=10
        '';
        # reports on host processes, devices and interfaces
        serviceConfig = {
          ProtectProc = "default";
          PrivateDevices = false;
        };
      };

      iperf3 = mkService {
        name = "iperf3";
        memoryMax = 250;
        exec = "${pkgs.iperf3}/bin/iperf3 --server --port 5201";
      };

      filebrowser = mkService {
        name = "filebrowser";
        memoryMax = 250;
        nice = 19;
        path = [ pkgs.filebrowser ];
        preStart = ''
          if [ ! -f /etc/filebrowser/filebrowser.db ]; then
            filebrowser config init \
              --address=0.0.0.0 --port=7777 --auth.method=noauth \
              --log=stdout --root=/shortcuts \
              --database=/etc/filebrowser/filebrowser.db
          fi
          # Every entry under /shortcuts is a symlink out of the scope, which
          # newer filebrowser refuses to serve unless this is set.
          filebrowser config set --followExternalSymlinks \
            --database=/etc/filebrowser/filebrowser.db
          # Databases created by the old preStart can hold no users, because
          # filebrowser rejects the default password. Nothing can log in then.
          if [ "$(filebrowser users ls --database=/etc/filebrowser/filebrowser.db | wc -l)" -lt 2 ]; then
            # filebrowser rejects passwords that are short or guessable, and
            # BlueOS's default is both. With auth.method=noauth the password is
            # never checked, so a random one is used to create the user.
            filebrowser users add ${cfg.user.name} "$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)" \
              --database=/etc/filebrowser/filebrowser.db
          fi
        '';
        exec = ''
          ${pkgs.filebrowser}/bin/filebrowser \
            --database /etc/filebrowser/filebrowser.db --baseurl /file-browser
        '';
        serviceConfig.ReadWritePaths = [ "/etc/filebrowser" ];
      };

      ttyd = mkService {
        name = "ttyd";
        memoryMax = 250;
        nice = 19;
        path = [ pkgs.tmux ];
        # -W: ttyd 1.7 runs read only without it
        exec = ''${pkgs.ttyd}/bin/ttyd -W -p 8088 ${pkgs.runtimeShell} -c "tmux attach -t user_terminal || tmux new -s user_terminal"'';
      };
    };
  };
}
