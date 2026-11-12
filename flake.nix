{
  description = "Droidloom for NixOS: host package and declarative module";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      droidloom = pkgs.callPackage ./nix/package.nix { droidloomSrc = self; };
      moduleEval = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          self.nixosModules.default
          ({ ... }: {
            networking.hostName = "droidloom-module-eval";
            boot.loader.grub.devices = [ "nodev" ];
            fileSystems."/" = {
              device = "/dev/null";
              fsType = "tmpfs";
            };
            system.stateVersion = "25.11";
            users.users.droidloom-test = {
              isNormalUser = true;
              uid = 1000;
            };
            services.droidloom = {
              enable = true;
              user = "droidloom-test";
              uid = 1000;
              manageSubIds = true;
              gpu = "0000:01:00.0";
              graphicsBackend = "forwarding";
            };
          })
        ];
      };
    in
    {
      nixosModules.default = import ./nix/module.nix;
      nixosModules.droidloom = self.nixosModules.default;

      packages.${system} = {
        default = droidloom.host;
        host = droidloom.host;
        android-artifacts = droidloom.androidArtifacts;
        runtime-metadata = droidloom.runtimeMetadata;
        advanced-protection-config = droidloom.advancedProtectionConfig;
      };

      checks.${system} = {
        host = droidloom.host;
        module-evaluation = pkgs.runCommand "droidloom-module-evaluation" { } ''
          echo ${
            if moduleEval.config.systemd.services ? droidloomd
              && moduleEval.config.systemd.services.droidloomd.serviceConfig.Delegate
              && moduleEval.config.systemd.services.droidloomd.serviceConfig.DelegateSubgroup == "droidloom"
              && builtins.elem "system_heap" moduleEval.config.boot.kernelModules
            then "ok"
            else throw "Droidloom module must delegate its cgroup subgroup and load the system DMA heap"
          } > "$out"
        '';
        advanced-protection-config = pkgs.runCommand "droidloom-advanced-protection-config-check" {
          nativeBuildInputs = [ pkgs.python3 ];
        } ''
          ${pkgs.python3}/bin/python3 - ${droidloom.advancedProtectionConfig} <<'PY'
import sys
from xml.etree import ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
protections = root.findall("./available-protections/protection")
if not protections:
    raise SystemExit("Advanced Protection config contains no protections")
if any("featureFlag" in protection.attrib for protection in protections):
    raise SystemExit("Advanced Protection config still has a featureFlag attribute")
PY
          echo passed > "$out"
        '';
      };
    };
}
