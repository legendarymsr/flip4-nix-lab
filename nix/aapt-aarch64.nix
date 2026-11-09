# Statically-linked aarch64 aapt / aapt2 for the Flip4 lab rootfs.
#
# Provenance: lzhiyong/android-sdk-tools release 35.0.2
#   https://github.com/lzhiyong/android-sdk-tools/releases/tag/35.0.2
# Built with Android NDK r27b as static Android-30 binaries (see `file` output).
# We only ship aapt + aapt2 from the zip (apktool needs aapt2 for `apktool b`;
# aapt is kept as a fallback for older apktool flags).
#
# Not built from AOSP here: a full soong/aapt2 build pulls a huge chunk of
# the Android build system and doesn't fit this box's disk. The upstream
# project is the same source Termux and similar mobile toolchains rely on
# for prebuilt aapt2 on aarch64.
{ pkgs }:
pkgs.stdenvNoCC.mkDerivation {
  pname = "aapt-aarch64";
  version = "35.0.2";
  src = pkgs.fetchurl {
    url = "https://github.com/lzhiyong/android-sdk-tools/releases/download/35.0.2/android-sdk-tools-static-aarch64.zip";
    hash = "sha256-2xzqLERU1fnFqAJkay0c9WC07nutviPlGrjhiBu1D8I=";
  };
  nativeBuildInputs = [ pkgs.unzip ];
  dontUnpack = true;
  dontFixup = true; # static Android NDK binaries; no dynamic linker to patch
  installPhase = ''
    mkdir -p $out/bin
    unzip -p $src build-tools/aapt2 > $out/bin/aapt2
    unzip -p $src build-tools/aapt  > $out/bin/aapt
    chmod 755 $out/bin/aapt2 $out/bin/aapt
  '';
  meta = {
    description = "Static aarch64 aapt/aapt2 from lzhiyong/android-sdk-tools 35.0.2";
    homepage = "https://github.com/lzhiyong/android-sdk-tools";
    license = pkgs.lib.licenses.asl20; # AOSP tools
    platforms = [ "aarch64-linux" ];
    sourceProvenance = [ pkgs.lib.sourceTypes.binaryNativeCode ];
  };
}
