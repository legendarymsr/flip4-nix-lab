# Builds a KernelSU module zip from a directory. Architecture-independent
# (only POSIX sh scripts), so it is built with the host's pkgs.
{ pkgs, name, src, version, extraFiles ? { } }:
let
  inherit (pkgs) lib;
  parts = lib.splitString "." version;
  versionCode = toString (lib.foldl' (acc: p: acc * 100 + lib.toInt p) 0 parts);
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
    substituteInPlace m/module.prop \
      --replace-fail @VERSION@ v${version} \
      --replace-fail @VERSIONCODE@ ${versionCode}
    find m -name '*.sh' -exec chmod 755 {} +
    [ -e m/mitmca-add ] && chmod 755 m/mitmca-add
    # Deterministic zip: fixed mtimes, sorted entries, no extra attrs.
    find m -exec touch -h -d @315532800 {} +
    mkdir -p $out
    (cd m && find . -mindepth 1 | LC_ALL=C sort | sed 's,^\./,,' | zip -X -q -@ $out/${name}-v${version}.zip)
  ''
