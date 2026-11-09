# Static aarch64 curl bundled into the nixchroot module so the on-device
# bootstrap has a TLS-verifying downloader on stock Android (busybox wget's
# TLS doesn't validate certificates; /system/bin/curl isn't guaranteed).
# Provenance: stunnel/static-curl 8.23.0-1 (musl, static-pie, OpenSSL 4.0.3)
#   https://github.com/stunnel/static-curl/releases/tag/8.23.0-1
# Binary sha256: 3a7c6818343f1b5184047bb484cb3cff7d5ede35a2713a6ef61030b422d8d6fc
{ pkgs }:
pkgs.stdenvNoCC.mkDerivation {
  pname = "static-curl-aarch64";
  version = "8.23.0-1";
  src = pkgs.fetchurl {
    url = "https://github.com/stunnel/static-curl/releases/download/8.23.0-1/curl-linux-aarch64-musl-8.23.0-1.tar.xz";
    hash = "sha256-4g8m5bh8GINgjyhvhr2r8507hVboqOdd/iBeFL0gYZk=";
  };
  dontUnpack = true;
  dontFixup = true;
  installPhase = ''
    mkdir -p $out/bin
    tar -xJf $src -C $out/bin curl
    echo "3a7c6818343f1b5184047bb484cb3cff7d5ede35a2713a6ef61030b422d8d6fc  $out/bin/curl" | sha256sum -c -
    chmod 755 $out/bin/curl
  '';
  meta.sourceProvenance = [ pkgs.lib.sourceTypes.binaryNativeCode ];
}
