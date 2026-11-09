# Builds a KernelSU module zip from a directory. Architecture-independent
# (only POSIX sh scripts), so it is built with the host's pkgs.
{ pkgs, name, src, version, extraFiles ? { }, pathFiles ? { } }:
let
  inherit (pkgs) lib;
  parts = lib.splitString "." version;
  versionCode = toString (lib.foldl' (acc: p: acc * 100 + lib.toInt p) 0 parts);
  # pathFiles: copied into the module only (e.g. bin/curl), not onto PATH.
  copyPath = lib.concatStringsSep "\n" (lib.mapAttrsToList (dst: file: ''
    install -Dm755 ${file} m/${dst}
  '') pathFiles);
  copyExtra = lib.concatStringsSep "\n" (lib.mapAttrsToList (dst: file: ''
    install -Dm755 ${file} m/${dst}
    # also expose it on PATH through KernelSU's system/ overlay (needs a
    # mounting metamodule on KernelSU >= 2.x; harmless without one)
    install -Dm755 ${file} m/system/bin/${baseNameOf dst}
  '') extraFiles);
in
pkgs.runCommand "ksu-${name}-${version}"
  { nativeBuildInputs = [ pkgs.zip pkgs.shellcheck ]; }
  ''
    mkdir m
    cp -r ${src}/. m/
    chmod -R u+w m
    ${copyExtra}
    ${copyPath}
    substituteInPlace m/module.prop \
      --replace-fail @VERSION@ v${version} \
      --replace-fail @VERSIONCODE@ ${versionCode}
    find m -name '*.sh' -exec chmod 755 {} +
    [ -e m/mitmca-add ] && chmod 755 m/mitmca-add
    [ -d m/bin ] && chmod 755 m/bin/*
    # Deterministic zip: fixed mtimes, sorted entries, no extra attrs.
    find m -exec touch -h -d @315532800 {} +
    mkdir -p $out
    (cd m && find . -mindepth 1 | LC_ALL=C sort | sed 's,^\./,,' | zip -X -q -9 -@ $out/${name}-v${version}.zip)
  ''
