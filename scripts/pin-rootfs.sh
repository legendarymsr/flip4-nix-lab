# pin-rootfs TAG [ROOTFS_DIR]
# Point the on-device bootstrap at a rootfs release asset: writes ./rootfs.json
# = ROOTFS_DIR/rootfs.json (built from the current flake.lock) + its release URL.
# Then upload ROOTFS_DIR/flip4-nix-rootfs-aarch64.tar.gz{,.sha256} and
# rootfs.json to release TAG and rebuild the modules/APK.
set -euo pipefail
tag=${1:?usage: pin-rootfs TAG [ROOTFS_DIR]}
dir=${2:-${FLIP4_ROOTFS_DIR:?build .#rootfs first or pass its dir}}
repo=${FLIP4_REPO:-legendarymsr/flip4-nix-lab}
[ -f flake.lock ] && [ -f flake.nix ] || { echo "run from the repo root" >&2; exit 1; }
want=$(jq -r .nodes.nixpkgs.locked.narHash flake.lock)
have=$(jq -r .lockHash "$dir/rootfs.json")
[ "$want" = "$have" ] || { echo "rootfs in $dir was built from $have, flake.lock has $want: rebuild it" >&2; exit 1; }
jq --arg url "https://github.com/$repo/releases/download/$tag/flip4-nix-rootfs-aarch64.tar.gz" \
   --arg release "$tag" '{url: $url, release: $release} + .' "$dir/rootfs.json" > rootfs.json.new
mv rootfs.json.new rootfs.json
cat rootfs.json
