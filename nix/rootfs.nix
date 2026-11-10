# Tarball assembly. `pkgs` is the BUILD host's package set; the closure itself
# is whatever arch rootfs-tree/lab-env are (aarch64). closureInfo only reads
# references, so it doesn't care about the closure's architecture.
# lock: the nixpkgs input this was built from, recorded in rootfs.json.
{ pkgs, rootfs-tree, lab-env, version, lock }:
let
  closure = pkgs.closureInfo { rootPaths = [ rootfs-tree lab-env ]; };
in
pkgs.runCommand "flip4-nix-rootfs-aarch64-${version}"
  {
    nativeBuildInputs = with pkgs; [ gnutar pigz jq ];
    passthru = { inherit closure rootfs-tree lab-env; };
  }
  ''
    mkdir -p $out work
    # rootfs-tree is a store path (read-only, r-x); copy the skeleton so we can
    # add the registration file and fix modes.
    cp -a ${rootfs-tree}/. work/
    chmod -R u+w work
    chmod 1777 work/tmp
    chmod 0700 work/root
    # Loaded by `nixroot` on first entry: `nix-store --load-db < /nix-path-registration`
    cp ${closure}/registration work/nix-path-registration
    : > work/.nix-db-pending
    mkdir -p work/nix/store
    chmod 0755 work/nix/store

    # Skeleton entries, non-recursive (we list every node), then the store
    # paths recursively. Ownership is forced to 0:0, symlinks are kept as-is,
    # mtimes normalised for reproducibility.
    (cd work && find . -mindepth 1 | sed 's,^\./,,' | LC_ALL=C sort) > skel.list
    sed 's,^/,,' ${closure}/store-paths > store.list

    tar --create --format=gnu --sort=name --mtime=@1 \
        --owner=0 --group=0 --numeric-owner \
        -C work --no-recursion -T skel.list \
        -C / --recursion -T store.list \
      | pigz -p "$NIX_BUILD_CORES" -9 > $out/flip4-nix-rootfs-aarch64.tar.gz

    sha256sum $out/flip4-nix-rootfs-aarch64.tar.gz | sed "s,  .*/,  ," > $out/flip4-nix-rootfs-aarch64.tar.gz.sha256
    cp ${closure}/store-paths $out/store-paths
    du -sb --apparent-size $(cat ${closure}/store-paths) | awk '{s+=$1} END {print s}' > $out/unpacked-bytes

    # Manifest shipped beside the tarball; repo-root rootfs.json is this plus
    # the release URL (scripts/pin-rootfs.sh). CI compares lockHash with flake.lock.
    jq -n \
      --arg name flip4-nix-rootfs-aarch64.tar.gz \
      --arg version ${version} \
      --arg sha256 "$(cut -d' ' -f1 $out/flip4-nix-rootfs-aarch64.tar.gz.sha256)" \
      --argjson size "$(stat -c %s $out/flip4-nix-rootfs-aarch64.tar.gz)" \
      --argjson unpackedBytes "$(cat $out/unpacked-bytes)" \
      --argjson storePaths "$(wc -l < ${closure}/store-paths)" \
      --arg lockHash ${lock.narHash} \
      --arg nixpkgsRev ${lock.rev} \
      --arg nixpkgsLastModified ${toString lock.lastModified} \
      '{name: $name, version: $version, sha256: $sha256, size: $size,
        unpackedBytes: $unpackedBytes, storePaths: $storePaths,
        lockHash: $lockHash,
        nixpkgs: {rev: $nixpkgsRev, narHash: $lockHash, lastModified: ($nixpkgsLastModified | tonumber)}}' \
      > $out/rootfs.json
  ''
