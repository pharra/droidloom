{ lib, rustPlatform, fetchurl, runCommand, zstd, gnutar,
  python3, pkg-config, clang, llvmPackages, libdrm, libgbm, mesa, wayland,
  libxkbcommon, pipewire, systemd, glibc, util-linux, coreutils,
  android-tools, polkit, iproute2, libGL, libffi, zlib, vulkan-loader,
  glslang, makeWrapper, erofs-utils, droidloomSrc }:
let
  upstreamVersion = "0.1.0-33";
  upstream = "https://github.com/denialwm/droidloom/releases/download/packages";
  source = lib.cleanSourceWith {
    src = droidloomSrc;
    filter = path: _type:
      let
        root = toString droidloomSrc;
        relative = lib.removePrefix "${root}/" (toString path);
        workspaceDirs = [ "android" "graphics" "protocol" "runtime" "tools" ];
      in
      toString path == root
      || builtins.elem relative [ "Cargo.lock" "Cargo.toml" ]
      || builtins.any (directory:
        relative == directory || lib.hasPrefix "${directory}/" relative
      ) workspaceDirs;
  };

  runtimeArchive = fetchurl {
    url = "${upstream}/droidloom-runtime-${upstreamVersion}-x86_64.pkg.tar.zst";
    hash = "sha256-c26gG69RetZUdEI2v+NaSz+rQVCp4RJORNdzJeb7T5E=";
  };
  imageArchive = fetchurl {
    url = "${upstream}/droidloom-image-${upstreamVersion}-x86_64.pkg.tar.zst";
    hash = "sha256-aE+jMQPofDTLwN1bmJwB7rDH7zTEkKaMZ+7w4BwdCmo=";
  };

  unpackPackage = kind: archive:
    runCommand "droidloom-${kind}-payload-${upstreamVersion}" {
      nativeBuildInputs = [ zstd gnutar ];
    } ''
      mkdir -p "$out"
      tar --use-compress-program=unzstd --no-same-owner -xf ${archive} -C "$out" usr
    '';

  androidArtifacts = unpackPackage "android" imageArchive;
  runtimeMetadata = unpackPackage "runtime" runtimeArchive;

  # The release 33 framework crashes when these featureFlag attributes refer
  # to an unavailable Aconfig package; extract its config and remove them.
  advancedProtectionConfig = runCommand "droidloom-advanced-protection-config-${upstreamVersion}" {
    nativeBuildInputs = [ erofs-utils python3 ];
  } ''
    ${erofs-utils}/bin/fsck.erofs \
      --extract="$TMPDIR/advanced-protection-config.xml" \
      --path=/system/etc/advanced-protection-config/advanced-protection-config.xml \
      ${androidArtifacts}/usr/lib/droidloom/images/images/system.img
    ${python3}/bin/python3 - "$TMPDIR/advanced-protection-config.xml" "$out" <<'PY'
import sys
from xml.etree import ElementTree as ET

source, destination = sys.argv[1:]
parser = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True))
tree = ET.parse(source, parser=parser)
for element in tree.iter("protection"):
    element.attrib.pop("featureFlag", None)
tree.write(destination, encoding="utf-8", xml_declaration=True)
PY
  '';

  host = rustPlatform.buildRustPackage {
    pname = "droidloom-nixos-host";
    version = upstreamVersion;
    src = source;
    cargoLock.lockFile = ../Cargo.lock;
    cargoBuildFlags = [
      "-p" "droidloom-supervisor"
      "-p" "droidloom-wayland"
      "-p" "droidloom-applications"
      "-p" "droidloom-audio"
      "-p" "droidloom-devices"
      "-p" "droidloom-doctor"
      "-p" "droidloom-gpu-server"
    ];
    cargoTestFlags = [
      "-p" "droidloom-cpu-placement"
      "-p" "droidloom-applications"
    ];
    nativeBuildInputs = [ pkg-config clang llvmPackages.libclang glslang makeWrapper ];
    LIBCLANG_PATH = "${llvmPackages.libclang.lib}/lib";
    buildInputs = [
      libdrm libgbm mesa wayland libxkbcommon pipewire libGL libffi zlib
      vulkan-loader
    ];
    doCheck = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin"
      for name in droidloomd droidloomctl droidloom-supervisor droidloom-wayland droidloom-applications droidloom-audio droidloom-devices droidloom-doctor droidloom-gpu-server; do
        install -m755 "target/x86_64-unknown-linux-gnu/release/$name" "$out/bin/$name"
      done
      for name in droidloomd droidloomctl droidloom-supervisor droidloom-wayland droidloom-applications droidloom-audio droidloom-devices droidloom-doctor droidloom-gpu-server; do
        if [ "$name" = droidloom-gpu-server ]; then
          wrapProgram "$out/bin/$name" \
            --set DROIDLOOM_BIN_PATH /run/current-system/sw/bin \
            --set DROIDLOOM_PACKAGE_VERSION /var/empty/droidloom-nixos-not-pacman \
            --prefix LD_LIBRARY_PATH : "${vulkan-loader}/lib"
        else
          wrapProgram "$out/bin/$name" \
            --set DROIDLOOM_BIN_PATH /run/current-system/sw/bin \
            --set DROIDLOOM_PACKAGE_VERSION /var/empty/droidloom-nixos-not-pacman
        fi
      done
      runHook postInstall
    '';
    meta = {
      description = "Experimental Droidloom Linux host programs for NixOS";
      homepage = "https://github.com/denialwm/droidloom";
      license = lib.licenses.gpl3Plus;
      platforms = [ "x86_64-linux" ];
    };
  };
in {
  inherit host androidArtifacts runtimeMetadata advancedProtectionConfig;
}
