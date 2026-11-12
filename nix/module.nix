{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkOption mkIf types;
  cfg = config.services.droidloom;
  packages = pkgs.callPackage ./package.nix { droidloomSrc = ../.; };
  host = packages.host;
  artifacts = packages.androidArtifacts;
  metadata = packages.runtimeMetadata;
  advancedProtectionConfig = packages.advancedProtectionConfig;
  uid = toString cfg.uid;
  userName = cfg.user;
  apkInstallScript = pkgs.writeShellScript "droidloom-declarative-apks" ''
    set -eu
    ${packages.host}/bin/droidloomctl wait
    ${lib.concatMapStringsSep "\n" (apk: ''
      ${packages.host}/bin/droidloomctl install --user 0 ${lib.escapeShellArg (toString apk)}
    '') cfg.applications}
  '';
  dataDir = "/var/lib/droidloom/nixos/users/${uid}/data";

  # Build the cell spec from the exact matching upstream package template.
  # Keep the Android binary payload entirely in the Nix store.
  cellSpec = pkgs.runCommand "droidloom-nixos-cell-${uid}.json" {
    nativeBuildInputs = [ pkgs.python3 ];
  } ''
    export DL_IMAGE_ROOT="${artifacts}/usr/lib/droidloom"
    export DL_UID="${uid}"
    export DL_RENDER_NODE="${cfg.renderNode}"
    export DL_GPU="${if cfg.gpu == null then "" else cfg.gpu}"
    export DL_GRAPHICS_BACKEND="${cfg.graphicsBackend}"
    export DL_ADVANCED_PROTECTION_CONFIG="${advancedProtectionConfig}"
    export DL_DATA_DIR="${dataDir}"
    export DL_SUB_ID_START="${toString cfg.subIdStart}"
    ${pkgs.python3}/bin/python3 - <<'PY'
import json
import os
from pathlib import Path

source = Path("${metadata}/usr/share/droidloom/cell-template.json")
spec = json.loads(source.read_text())
root = os.environ["DL_IMAGE_ROOT"]

def rewrite(value):
    if isinstance(value, str) and value.startswith("/usr/lib/droidloom/"):
        return root + value[len("/usr/lib/droidloom"):]
    if isinstance(value, list):
        return [rewrite(item) for item in value]
    if isinstance(value, dict):
        return {key: rewrite(item) for key, item in value.items()}
    return value

spec = rewrite(spec)
uid = int(os.environ["DL_UID"])
spec.update({
    "host_uid": uid,
    "render_node": os.environ["DL_RENDER_NODE"],
    "data_dir": os.environ["DL_DATA_DIR"],
    "runtime_dir": f"/run/droidloom/cells/u{uid}",
    "denial_socket": f"/run/user/{uid}/droidloom/native-bridge.sock",
    "shared_storage_directories": [],
    "subordinate_uids": {"start": int(os.environ["DL_SUB_ID_START"]), "count": 100000},
    "subordinate_gids": {"start": int(os.environ["DL_SUB_ID_START"]), "count": 100000},
})
if os.environ["DL_GPU"]:
    spec["gpu"] = os.environ["DL_GPU"]
else:
    spec.pop("gpu", None)
spec["graphics_backend"] = os.environ["DL_GRAPHICS_BACKEND"]
override_target = "/system/etc/advanced-protection-config/advanced-protection-config.xml"
overrides = spec.setdefault("android_file_overrides", [])
overrides[:] = [entry for entry in overrides if entry.get("target") != override_target]
overrides.append({
    "source": os.environ["DL_ADVANCED_PROTECTION_CONFIG"],
    "target": override_target,
})
Path(os.environ["out"]).write_text(json.dumps(spec, indent=2) + "\n")
PY
  '';
in
{
  options.services.droidloom = {
    enable = mkEnableOption "experimental native Droidloom Android runtime";
    user = mkOption {
      type = types.str;
      default = "";
      example = "kori";
      description = "Existing host login used to run the Wayland session.";
    };
    uid = mkOption {
      type = types.ints.positive;
      default = 1000;
      description = "Numeric UID of the existing Wayland user. Must match id -u.";
    };
    renderNode = mkOption {
      type = types.str;
      default = "/dev/dri/renderD128";
      description = "DRM render node exposed to Android. Check /sys/class/drm before enabling.";
    };
    gpu = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "0000:03:00.0";
      description = "GPU vendor or PCI address used by Android Vulkan applications.";
    };
    graphicsBackend = mkOption {
      type = types.enum [ "drm" "drm_dma_heap" "kgsl_dma_heap" "forwarding" ];
      default = "drm";
      description = "Android graphics backend; use forwarding for NVIDIA GPUs without an Android driver.";
    };
    applications = mkOption {
      type = types.listOf (types.either types.path types.package);
      default = [];
      example = lib.literalExpression ''[ ./apks/example.apk ]'';
      description = ''Standalone APKs to install or update after Android starts.
        Files added or changed here are stored under /nix/store. Removing an
        APK from this list does not uninstall it from the Android user profile.'';
    };
    autoStart = mkOption {
      type = types.bool;
      default = false;
      description = "Start Droidloom automatically upon entering the graphical session";
    };
    manageSubIds = mkOption {
      type = types.bool;
      default = false;
      description = "Declare a contiguous subordinate UID/GID range for the Droidloom user";
    };
    subIdStart = mkOption {
      type = types.ints.positive;
      default = 100000;
      description = "Start of the 100000-id subordinate ranges (check collisions first)";
    };
    enableIpv4Forwarding = mkOption {
      type = types.bool;
      default = false;
      description = "Opt in to host IPv4 forwarding; may interact with firewall or VPN policies.";
    };
  };

  config = mkIf cfg.enable {
    # Only edit the declared user's subordinate ID maps when explicitly enabled.
    users.users.${userName} = lib.mkIf cfg.manageSubIds {
      autoSubUidGidRange = lib.mkForce false;
      subUidRanges = lib.mkForce [ { startUid = cfg.subIdStart; count = 100000; } ];
      subGidRanges = lib.mkForce [ { startGid = cfg.subIdStart; count = 100000; } ];
    };
    assertions = [
      {
        assertion = cfg.user != "";
        message = "services.droidloom.user must be an existing Linux login";
      }
      {
        assertion = lib.hasPrefix "/dev/dri/renderD" cfg.renderNode;
        message = "services.droidloom.renderNode must be an absolute DRM render node";
      }
    ];

    environment.systemPackages = [ host pkgs.android-tools ];
    security.polkit.enable = true;
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id === "org.freedesktop.systemd1.manage-units" &&
            subject.user === ${builtins.toJSON cfg.user} &&
            action.lookup("unit") === "droidloomd.service" &&
            (action.lookup("verb") === "start" || action.lookup("verb") === "stop")) {
          return polkit.Result.YES;
        }
      });
    '';

    boot.kernelModules =
      [ "binder_linux" "fuse" ]
      ++ lib.optionals (cfg.graphicsBackend != "drm") [ "system_heap" ];
    boot.kernel.sysctl = mkIf cfg.enableIpv4Forwarding {
      "net.ipv4.ip_forward" = 1;
    };

    # The daemon validates ownership of the spec and refuses a symlink.
    # Keep /etc/droidloom/cell.json a regular root-owned file.
    system.activationScripts.droidloom = {
      deps = [ "etc" ];
      text = ''
        if [ -L /etc/droidloom ]; then
          echo 'Droidloom: refusing a symlinked /etc/droidloom directory' >&2
          exit 1
        fi
        ${pkgs.coreutils}/bin/install -d -m 0755 /etc/droidloom
        if [ -e /etc/droidloom/cell.json ] && [ ! -e /etc/droidloom/.nixos-port-managed ]; then
          # Preserve configuration created by a previous non-NixOS installation.
          ${pkgs.coreutils}/bin/cp -a /etc/droidloom/cell.json /etc/droidloom/cell.json.before-nixos-flake
        fi
        ${pkgs.coreutils}/bin/install -m 0644 ${cellSpec} /etc/droidloom/cell.json.nix-new
        ${pkgs.coreutils}/bin/mv -f /etc/droidloom/cell.json.nix-new /etc/droidloom/cell.json
        ${pkgs.coreutils}/bin/touch /etc/droidloom/.nixos-port-managed

      '';
    };

    systemd.services.droidloomd = {
      description = "Droidloom Android cell lifecycle daemon (NixOS experiment)";
      after = [ "network.target" ];
      path = with pkgs; [
        host coreutils util-linux iproute2 nftables iptables android-tools
        e2fsprogs systemd procps findutils gnugrep gnused
      ];
      preStart = ''
        # Only create missing directories. Never reset ownership/mode of data
        # that Android has already initialized.
        for dir in /var/lib/droidloom /var/lib/droidloom/nixos \
          /var/lib/droidloom/nixos/users /var/lib/droidloom/nixos/users/${uid} ${dataDir} \
          ${dataDir}/data ${dataDir}/metadata; do
          if [ -L "$dir" ]; then
            echo "Refusing symlinked Android storage directory: $dir" >&2
            exit 1
          fi
          if [ ! -e "$dir" ]; then
            mkdir "$dir"
            if [ "$dir" = "${dataDir}" ] || [ "$dir" = "${dataDir}/data" ] || [ "$dir" = "${dataDir}/metadata" ]; then
              chmod 0700 "$dir"
            else
              chmod 0755 "$dir"
            fi
          fi
        done
      '';
      serviceConfig = {
        Type = "simple";
        # Android netd attaches egress BPF to its cgroup namespace root. Keep
        # that root below the systemd unit cgroup, which rejects BPF attaches.
        Delegate = true;
        DelegateSubgroup = "droidloom";
        ExecStart = "${host}/bin/droidloomd";
        TimeoutStopSec = "20s";
        KillMode = "mixed";
        OOMPolicy = "continue";
        Restart = "on-failure";
        RestartSec = "1s";
        RuntimeDirectory = "droidloom";
        RuntimeDirectoryMode = "0755";
      };
      # This system unit is not enabled at boot. The user unit starts it.
    };

    systemd.user.services.droidloom = {
      description = "Droidloom Android Wayland runtime (experimental)";
      partOf = [ "graphical-session.target" ];
      after = [
        "graphical-session-pre.target"
        "droidloom-audio.socket"
        "droidloom-devices.socket"
        "droidloom-gpu.socket"
      ];
      wants = [
        "droidloom-applications.service"
        "droidloom-audio.socket"
        "droidloom-devices.socket"
        "droidloom-gpu.socket"
        "droidloom-recovery.service"
      ];
      wantedBy = lib.optionals cfg.autoStart [ "graphical-session.target" ];
      unitConfig = {
        ConditionPathExists = "/etc/droidloom/cell.json";
        ConditionUser = cfg.user;
      };
      serviceConfig = {
        Type = "notify";
        NotifyAccess = "main";
        Environment = [
          "DROIDLOOM_MODE=desktop"
          "DROIDLOOM_HOST_PEER_PID=0"
          "DROIDLOOM_HOST_PEER_UID=${uid}"
          "DROIDLOOM_HOST_PEER_GID=${uid}"
          "DROIDLOOM_RENDER_NODE=${cfg.renderNode}"
        ];
        EnvironmentFile = [ "-%t/droidloom/session.env" ];
        ExecStartPre = "${pkgs.systemd}/bin/systemctl start droidloomd.service";
        ExecStart = "${host}/bin/droidloom-wayland";
        ExecStartPost = "${host}/bin/droidloomctl start --cell";
        ExecStopPost = [
          "-${host}/bin/droidloomctl stop --cell"
          "${pkgs.systemd}/bin/systemctl stop droidloomd.service"
        ];
        Restart = "on-failure";
        RestartSec = "1s";
        TimeoutStartSec = 150;
        TimeoutStopSec = 150;
      };
    };

    systemd.user.services.droidloom-apks = lib.mkIf (cfg.applications != []) {
      description = "Install declared Droidloom APKs after Android boots";
      after = [ "droidloom.service" ];
      wantedBy = [ "droidloom.service" ];
      unitConfig.ConditionUser = cfg.user;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = apkInstallScript;
        TimeoutStartSec = "360s";
      };
    };

    systemd.user.services.droidloom-applications = {
      description = "Droidloom desktop applications catalog";
      partOf = [ "droidloom.service" ];
      after = [ "droidloom.service" ];
      unitConfig.ConditionPathExists = "/etc/droidloom/cell.json";
      serviceConfig = {
        Type = "simple";
        Environment = [ "DROIDLOOM_CTL=${host}/bin/droidloomctl" ];
        ExecStart = "${host}/bin/droidloom-applications";
        Restart = "on-failure";
        RestartSec = "2s";
      };
    };

    systemd.user.sockets.droidloom-audio = {
      description = "Droidloom private Android audio socket";
      partOf = [ "droidloom.service" ];
      socketConfig = {
        ListenSequentialPacket = "%t/droidloom/audio.sock";
        SocketMode = "0666";
        DirectoryMode = "0700";
        RemoveOnStop = true;
      };
    };
    systemd.user.services.droidloom-audio = {
      description = "Droidloom host PipeWire broker";
      after = [ "pipewire.socket" ];
      wants = [ "pipewire.socket" ];
      partOf = [ "droidloom.service" ];
      requires = [ "droidloom-audio.socket" ];
      serviceConfig = {
        ExecStart = "${host}/bin/droidloom-audio --socket %t/droidloom/audio.sock";
        EnvironmentFile = [ "-%h/.config/droidloom/audio.env" ];
        Restart = "on-failure";
        RestartSec = "1s";
        NoNewPrivileges = true;
        RestrictSUIDSGID = true;
      };
    };
    systemd.user.sockets.droidloom-devices = {
      description = "Droidloom private Android device endpoints";
      partOf = [ "droidloom.service" ];
      socketConfig = {
        ListenSequentialPacket = [
          "%t/droidloom/haptics.sock"
          "%t/droidloom/camera.sock"
          "%t/droidloom/fingerprint.sock"
        ];
        SocketMode = "0666";
        DirectoryMode = "0700";
        RemoveOnStop = true;
      };
    };
    systemd.user.services.droidloom-devices = {
      description = "Droidloom host haptics, camera and fingerprint broker";
      partOf = [ "droidloom.service" ];
      requires = [ "droidloom-devices.socket" ];
      serviceConfig = {
        ExecStart = "${host}/bin/droidloom-devices";
        Restart = "on-failure";
        RestartSec = "1s";
        NoNewPrivileges = true;
        RestrictSUIDSGID = true;
      };
    };
    systemd.user.sockets.droidloom-gpu = {
      description = "Droidloom GPU forwarding endpoint";
      partOf = [ "droidloom.service" ];
      socketConfig = {
        ListenStream = "%t/droidloom/gpu.sock";
        SocketMode = "0666";
        DirectoryMode = "0700";
        RemoveOnStop = true;
      };
    };
    systemd.user.services.droidloom-gpu = {
      description = "Droidloom GPU server: Android Vulkan on the host driver";
      partOf = [ "droidloom.service" ];
      requires = [ "droidloom-gpu.socket" ];
      serviceConfig = {
        ExecStart = "${host}/bin/droidloom-gpu-server";
        Environment = lib.optional (cfg.gpu != null) "DROIDLOOM_GPU=${cfg.gpu}";
        Restart = "on-failure";
        RestartSec = "1s";
        NoNewPrivileges = true;
        RestrictSUIDSGID = true;
      };
    };
    systemd.user.services.droidloom-recovery = {
      description = "Droidloom Android cell crash recovery";
      bindsTo = [ "droidloom.service" ];
      partOf = [ "droidloom.service" ];
      after = [ "droidloom.service" ];
      unitConfig = {
        ConditionPathExists = "/etc/droidloom/cell.json";
        StartLimitIntervalSec = 300;
        StartLimitBurst = 5;
      };
      serviceConfig = {
        Type = "simple";
        ExecStartPre = "${pkgs.systemd}/bin/systemctl start droidloomd.service";
        ExecStart = "${host}/bin/droidloomctl supervise --cell";
        Restart = "on-failure";
        RestartSec = "5s";
        TimeoutStartSec = 150;
        TimeoutStopSec = 10;
      };
    };
  };
}
