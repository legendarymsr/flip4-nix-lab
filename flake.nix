{
  description = "Flip4 Android security lab: aarch64 Nix chroot (not proot) for a KernelSU-rooted Galaxy Z Flip4 on stock One UI 7 / Android 15";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      version = "0.2.0";
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});

      # The phone. Native aarch64 package set: everything heavy is substituted
      # from cache.nixos.org; only tiny glue derivations (buildEnv, wrappers,
      # writeText) have to be built for aarch64-linux, which on an x86_64 host
      # means binfmt/qemu or a remote builder (see README "Building").
      targetPkgs = nixpkgs.legacyPackages.aarch64-linux;

      mkLab = { host, target }: rec {
        lab-env = import ./nix/lab-env.nix { pkgs = target; };
        rootfs-tree = import ./nix/rootfs-tree.nix { pkgs = target; inherit lab-env; };
        # Assembly (closure walk + tar + gzip) runs on the *build* host, so on
        # x86_64 we don't burn time compressing GBs under qemu.
        rootfs = import ./nix/rootfs.nix { pkgs = host; inherit rootfs-tree lab-env version; };
      };

      mkModules = pkgs: {
        ksu-module = import ./nix/ksu-module.nix {
          inherit pkgs version;
          name = "nixchroot";
          src = ./modules/nixchroot;
          extraFiles = { "nixroot" = ./scripts/nixroot; };
          pathFiles = { "bin/curl" = "${import ./nix/static-curl-aarch64.nix { inherit pkgs; }}/bin/curl"; };
        };
        ksu-mitm-cacert-module = import ./nix/ksu-module.nix {
          inherit pkgs version;
          name = "mitm-cacert";
          src = ./modules/mitm-cacert;
        };
      };

      hostScripts = pkgs: lab: modules: {
        install = pkgs.writeShellApplication {
          name = "flip4-lab-install";
          runtimeInputs = with pkgs; [ android-tools coreutils gnugrep ];
          # `nix run .#install` builds the rootfs and uses it by default.
          runtimeEnv.FLIP4_ROOTFS = "${lab.rootfs}/flip4-nix-rootfs-aarch64.tar.gz";
          text = builtins.readFile ./scripts/install.sh;
        };
        mitm-ca-prep = pkgs.writeShellApplication {
          name = "flip4-mitm-ca-prep";
          runtimeInputs = with pkgs; [ android-tools openssl coreutils ];
          text = builtins.readFile ./scripts/mitm-ca-prep.sh;
        };
        push-modules = pkgs.writeShellApplication {
          name = "flip4-push-modules";
          runtimeInputs = with pkgs; [ android-tools coreutils ];
          runtimeEnv.FLIP4_MODULES = "${modules.ksu-module}/nixchroot-v${version}.zip ${modules.ksu-mitm-cacert-module}/mitm-cacert-v${version}.zip";
          text = builtins.readFile ./scripts/push-modules.sh;
        };
      };
    in
    {
      packages = forAllSystems (system: pkgs:
        let
          native = mkLab { host = pkgs; target = targetPkgs; };
          modules = mkModules pkgs;
        in
        native // modules // hostScripts pkgs native modules // {
          default = native.rootfs;
          # Phone-side helper, handy for `nix build .#nixroot` and copying around.
          nixroot = pkgs.runCommand "nixroot" { } "install -Dm755 ${./scripts/nixroot} $out/bin/nixroot";
        }
        // lib.optionalAttrs (system == "x86_64-linux") (
          let cross = mkLab { host = pkgs; target = pkgs.pkgsCross.aarch64-multiplatform; };
          in {
            # Pure cross build: no binfmt needed, but NOTHING is in the binary
            # cache for pkgsCross, so this compiles the world (JDK, Python,
            # frida, rizin...) and several packages are not cross-clean.
            # Best effort; prefer `.#rootfs` with binfmt. See README.
            rootfs-cross = cross.rootfs;
            lab-env-cross = cross.lab-env;
          }));

      apps = forAllSystems (system: pkgs:
        let s = self.packages.${system}; in {
          install = { type = "app"; program = lib.getExe s.install; meta.description = "adb push + extract rootfs to /data/local/nix"; };
          mitm-ca-prep = { type = "app"; program = lib.getExe s.mitm-ca-prep; meta.description = "hash a CA PEM to <subject_hash_old>.0 and push it"; };
          push-modules = { type = "app"; program = lib.getExe s.push-modules; meta.description = "adb push + ksud module install"; };
          default = self.apps.${system}.install;
        });

      checks = forAllSystems (system: pkgs: {
        shellcheck = pkgs.runCommand "flip4-lab-shellcheck" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
          cd ${./.}
          # Phone-side scripts run under KernelSU's busybox ash / mksh: POSIX sh.
          shellcheck -s sh -x \
            modules/nixchroot/*.sh scripts/nixroot \
            modules/mitm-cacert/*.sh modules/mitm-cacert/mitmca-add
          # Host-side scripts are bash.
          shellcheck -s bash scripts/install.sh scripts/mitm-ca-prep.sh scripts/push-modules.sh
          touch $out
        '';
        modules = pkgs.runCommand "flip4-lab-module-zips" { nativeBuildInputs = [ pkgs.unzip ]; } ''
          for z in ${self.packages.${system}.ksu-module}/*.zip ${self.packages.${system}.ksu-mitm-cacert-module}/*.zip; do
            unzip -l "$z"
            unzip -p "$z" module.prop | grep -q '^id='
          done
          touch $out
        '';
      });

      devShells = forAllSystems (system: pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [ android-tools shellcheck openssl zip unzip ];
        };
      });

      formatter = forAllSystems (system: pkgs: pkgs.nixfmt);
    };
}
