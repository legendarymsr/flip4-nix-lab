# flip4-nix-lab

An aarch64 Nix userland running as a **real `chroot`** (not proot) on a
Galaxy Z Flip4 (SM8475, `taro`) on stock One UI 7 / Android 15, rooted with
KernelSU on a GKI kernel. Native speed, the same network stack and `/proc`
as Android, and a Nix you can `nix build` with on the phone.

```
flake.nix
├── packages.<sys>.rootfs                 tarball: /nix/store closure + /etc + profile
├── packages.<sys>.lab-env                the toolset buildEnv (= /nix/var/nix/profiles/default)
├── packages.<sys>.ksu-module             nixchroot-vX.zip      (boot-time mounts, sshd, nixroot)
├── packages.<sys>.ksu-mitm-cacert-module mitm-cacert-vX.zip    (CA -> Conscrypt APEX store, A14/15)
├── packages.x86_64-linux.rootfs-cross    pure pkgsCross build (best effort, see below)
├── apps.<sys>.install                    adb push + extract to /data/local/nix
├── apps.<sys>.push-modules               adb push + `ksud module install`
├── apps.<sys>.mitm-ca-prep               CA PEM -> <subject_hash_old>.0 -> phone
└── checks.<sys>.{shellcheck,modules}
```

`<sys>` is `x86_64-linux` or `aarch64-linux`; the rootfs is always aarch64.

## Install on the phone (no PC): the app

Needs: KernelSU (GKI) with its manager app, ~5 GiB free on `/data`, Wi-Fi.

1. In the phone's browser, download
   [**`flip4-nix-lab-0.3.1.apk`**](https://github.com/legendarymsr/flip4-nix-lab/releases/download/v0.3.1/flip4-nix-lab-0.3.1.apk) and open it.
   Allow "install unknown apps" for the browser when asked. If Play Protect
   warns, tap **More details → Install anyway**. It's a sideloaded app that
   asks for root, so the warning is expected.
2. **KernelSU manager → Superuser → Flip4 Nix Lab → on.** KernelSU has no
   pop-up root prompt; the app just shows "Grant root" until you do this.
   Then tap **Refresh** in the app.
3. Tap **Install module** (tick *also install mitm-cacert* if you want
   system-wide CA injection), then **Reboot**.
4. Open the app again and tap **Set up**. It downloads the rootfs (~1.2 GiB, resumable),
   verifies the sha256, extracts (~3 GiB) and mounts, with progress and the
   live log. The job runs detached from the app as root (out of the app's
   cgroup, with a wakelock), so you can leave the app; reopen it to re-attach. If it's
   interrupted, tap **Set up** again and it resumes.
5. Tap **Open shell (Termux)**. The first time it offers to set
   `allow-external-apps = true` in Termux (via root) and asks for Termux's
   "Run commands in Termux environment" permission. Without Termux, use the
   **Run in chroot** box in the app (one-shot commands, output in the log).

Other buttons: **Use local tarball…** (pick an already-downloaded
`flip4-nix-rootfs-aarch64.tar.gz`; it's streamed to `/data` as root and
sha256-checked), **Mount / Unmount**, **Reinstall** (`--bootstrap --force`),
**Pick CA file… / Use chroot's mitmproxy CA** (runs `mitmca-add`, then
reboot), **Status** (`nixroot --status`).

What the app is: one Kotlin activity, ~90 KB of dex, no AndroidX and no Google
services. Everything it does is a visible shell command run through `su`
(see `companion/src/.../Lab.kt`). It bundles the two module zips from the
same release. Get Termux from **F-Droid** (or its GitHub releases); the Play
Store build is old.

### Without the app: module zips only

1. Download [`nixchroot-v0.3.1.zip`](https://github.com/legendarymsr/flip4-nix-lab/releases/download/v0.3.1/nixchroot-v0.3.1.zip)
   (and optionally [`mitm-cacert-v0.3.1.zip`](https://github.com/legendarymsr/flip4-nix-lab/releases/download/v0.3.1/mitm-cacert-v0.3.1.zip)) in the browser.
2. KernelSU manager → **Modules** → **Install** → pick the zip(s) → **Reboot**.
3. Modules → nixchroot → **Action** (▶), or in Termux: `su -c 'nixroot --bootstrap'`.
4. Enter: `su -c nixroot`.

Details:
- The rootfs download is pinned to the
  [v0.2.0 release asset](https://github.com/legendarymsr/flip4-nix-lab/releases/download/v0.2.0/flip4-nix-rootfs-aarch64.tar.gz)
  (it hasn't changed since; not re-uploaded) and its sha256
  (`88e34433…f45d`) is baked into the module (`bootstrap.sh`). Nothing is
  extracted unless the hash matches. The module ships a static aarch64 curl
  (stunnel/static-curl 8.23.0, hash-pinned at build time) that verifies TLS
  against Android's CA store and resolves names over DNS-over-HTTPS to
  1.1.1.1 / 9.9.9.9, because a static binary can't use Android's resolver. If that
  fails it falls back to `/system/bin/curl`, then busybox `wget` (busybox wget
  doesn't check TLS certificates; the sha256 check still applies).
- If `/sdcard/Download/flip4-nix-rootfs-aarch64.tar.gz` exists, the bootstrap
  uses it instead of downloading. Or: `su -c 'nixroot --bootstrap --file /path'`.
- Reinstall or upgrade: `su -c 'nixroot --bootstrap --force'` (unmounts first and
  backs up `etc` to `etc.bak-<ts>`). The partial download sits in
  `/data/local/tmp/nixchroot-dl/` and is deleted after a successful extract.
- `nixroot` is linked into `/data/adb/ksu/bin` (on `su`'s PATH), so no
  mounting metamodule is needed.

### Companion app: build and signing

```sh
nix build .#companion-apk          # result/flip4-nix-lab-<v>-unsigned.apk (reproducible) + -debug.apk
nix build .#checks.x86_64-linux.companion-tests   # JVM tests of the shell-command logic
FLIP4_KEYSTORE=release.jks FLIP4_KEY_PASS=... nix run .#sign-apk -- result/*-unsigned.apk out.apk
```

No Gradle: `nix/companion-apk.nix` runs aapt2, kotlinc, R8 and zipalign from a
pinned androidenv SDK. androidenv's build-tools need a 32-bit ncurses, so add
`extra-platforms = i686-linux` to `nix.conf` (x86_64 hosts only).
The unsigned APK is bit-for-bit reproducible (checked with `nix build --rebuild`).
`-debug.apk` is signed with a key generated during the build, so each build has a
different signature and can't update another. Release APKs are signed with
the maintainer's key (certificate SHA-256
`32:FF:BC:59:9D:9E:2C:9E:98:58:64:71:C7:2B:85:B1:B2:AD:4D:23:B5:AE:90:FD:10:8A:81:5F:B3:AC:F1:5F`).
The key is not in the repo; CI (`.github/workflows/companion-apk.yml`) signs with
it from repository secrets when they're set, and otherwise uploads the debug build.
Check a download with `apksigner verify --print-certs`.

## What's in the rootfs

| | |
|---|---|
| base | `nix` (single-user), bash, coreutils/findutils/grep/sed/awk, tar/gzip/xz/zstd, util-linux, procps, iproute2, ncurses (terminfo), cacert, openssh, openssl, curl, git, tmux, vim, strace |
| lab | `frida-tools`, `mitmproxy`, `jadx`, `apktool` (with aarch64 aapt2), `aapt`/`aapt2`, `dex2jar`, `rizin`, `android-tools` (adb/fastboot), `tcpdump`, `nmap`, `socat`, `sqlite`, `binwalk`, `gdb` |
| python3 (3.14) | frida-python, androguard, pwntools, cryptography, pycryptodome, requests, httpx, websockets, protobuf, lxml, pyyaml, rich, ipython, capstone, keystone-engine, unicorn, lief, pyelftools, construct, hexdump, scapy, rzpipe |
| helpers | `lab-frida-version` (which `frida-server` to put on the Android side) |

Everything is pinned by `flake.lock` (nixos-unstable, rev `f4a03c0`, 2026-11-07). Edit `nix/lab-env.nix`
to change the set. Inside the chroot you can also just `nix shell nixpkgs#foo`.

**Notes / overrides:**

- `apktool` + `aapt`/`aapt2`: nixpkgs' apktool wraps Google's prebuilt aapt,
  which is x86_64/darwin-only. This flake overrides it with a static aarch64
  aapt2 (and aapt) from [lzhiyong/android-sdk-tools 35.0.2](https://github.com/lzhiyong/android-sdk-tools/releases/tag/35.0.2)
  (NDK r27b, Android-30 static). See `nix/aapt-aarch64.nix`. Both `apktool d`
  and `apktool b` work in the chroot.
- `mitmproxy`: at the pinned 12.3.0, `test_emudhra` fails on every architecture
  under CPython 3.14. CPython 3.14 hard-rejects the compromised eMudhra
  intermediate SPKI that `--emudhra` deliberately uses
  ([python/cpython#160040](https://github.com/python/cpython/issues/160040)),
  and the 12.3.0 test drove the client side with stdlib `ssl`. Fixed by applying
  upstream [mitmproxy#8568](https://github.com/mitmproxy/mitmproxy/pull/8568)
  (`992052ee`) so the test uses mitmproxy's OpenSSL stack on both sides; full
  suite passes with no tests disabled (`patches/mitmproxy-8568-…patch`).
- `iptables` is intentionally **not** in the chroot. Android 15 uses
  iptables-legacy tables managed by netd; use `/system/bin/iptables` from the
  Android side (see "Interception").

## Building it yourself (PC, optional)

You only need this if you want to change the toolset; the release assets above are built from this flake.

```sh
nix build .#rootfs          # -> result/flip4-nix-rootfs-aarch64.tar.gz (+ .sha256, store-paths)
nix build .#ksu-module .#ksu-mitm-cacert-module
nix flake check             # shellcheck + module zip sanity
```

Nearly the whole closure is substituted from cache.nixos.org's aarch64
builds (~1.2 GiB download, ~3.3 GiB unpacked). A handful of derivations are
not in the cache and must be *built for aarch64-linux*: the buildEnv/wrapper
glue, `python3.withPackages`, the apktool override, the minimal JRE apktool
jlinks, and (at the pinned rev) `python3Packages.mitmproxy`. The tarball
assembly itself (closure walk, tar, pigz) always runs on the build host.

### On an aarch64-linux machine

Just `nix build .#rootfs`.

### From x86_64-linux via binfmt (recommended)

On NixOS:

```nix
boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
# nix.settings.extra-platforms is set for you by the binfmt module
```

Elsewhere: register `qemu-aarch64-static` with the `F` (fix-binary) flag so
it works inside the Nix sandbox, and add `extra-platforms = aarch64-linux` to
`nix.conf`. Then `nix build .#rootfs` as normal. Only the few glue
derivations above run under qemu (mitmproxy's test suite is the slow one,
think minutes, not hours). A remote aarch64 builder (`--builders`) works the
same way.

Testing the rootfs on the laptop under qemu-user (`sudo chroot` into an
extracted copy) works for almost everything, with two qemu artifacts that do
**not** happen on the phone:

- register binfmt with the **P** (preserve-argv0) flag, or Python envs lose
  their site-packages (nixpkgs' python wrappers rely on `--inherit-argv0`);
- sshd can't accept logins under qemu-user: `sshd-auth` installs a seccomp
  sandbox and qemu-user doesn't implement `PR_SET_SECCOMP`
  (`ssh_sandbox_child: prctl(PR_SET_SECCOMP): Invalid argument`). The Android
  kernel has seccomp, so this is fine on-device.

### From x86_64-linux via pkgsCross (`.#rootfs-cross`)

```sh
nix build .#rootfs-cross
```

No emulation needed, but `pkgsCross.aarch64-multiplatform` outputs are **not
in the binary cache**, so this compiles everything from source (GCC, a JDK
for jadx, Python + all modules, frida, rizin, nmap...), and several of those
(JDK, some Python C extensions, frida's prebuilt devkit fetches) are not
reliably cross-clean. It evaluates; whether it builds at a given nixpkgs rev
is luck. Use binfmt unless you have a reason not to. (Cross store paths also
differ from native ones, so `nix` on the phone can't substitute updates for
them.)

### Installing from a PC (adb)

Prereqs on the phone: KernelSU manager → Superuser → grant **Shell**
(`com.android.shell`) root. One UI 7: Settings → Security and privacy →
**Auto Blocker off** (it blocks USB debugging commands).

```sh
nix run .#install                 # builds .#rootfs if needed, pushes, verifies sha256, extracts
nix run .#push-modules            # installs nixchroot + mitm-cacert via ksud
adb reboot
```

`install.sh` options: `-s SERIAL`, `--root /data/local/nix`, `--force`
(runs `nixroot --umount` first when upgrading a live chroot), `--stream`
(pipe through `adb exec-in`, no temp copy in `/data/local/tmp`). It can also
run on the phone itself as root: `sh install.sh /sdcard/Download/flip4-nix-rootfs-aarch64.tar.gz`.

What it does: refuses if anything is mounted under `$NIXROOT` (extracting
over a bound `/dev` is how you end up deleting device nodes), checks `/data`
free space, backs up an existing `$NIXROOT/etc` to `etc.bak-<ts>`, extracts
with KernelSU's busybox `gzip -dc | tar -xpf -` as root. The archive is
created with `--owner=0 --group=0 --numeric-owner`, store modes intact,
symlinks stored as symlinks, so it comes out root-owned with no fixups.
Always extract under `/data`, never `/sdcard`: FUSE/sdcardfs has no real
ownership, modes or symlinks.

Upgrades extract on top: new store paths are added, the profile symlink is
replaced, and `.nix-db-pending` makes the next `nixroot` re-register the
closure. Old paths stay until you `nix-collect-garbage -d` inside.

## Entering

```sh
adb shell su -c nixroot          # if system/bin overlay is active (see quirks)
adb shell su -c 'sh /data/adb/modules/nixchroot/nixroot'
# from a terminal app:
su -c nixroot
nixroot mitmproxy --mode transparent --showhost      # run a command
nixroot --status | --mount | --remount | --umount
```

First entry runs `nix-store --load-db < /nix-path-registration` so the Nix
inside knows its own store, then you're in a clean `env -i` login shell
(Android's `BOOTCLASSPATH`, `LD_*`, `ANDROID_*` don't leak in).

`nixroot` re-execs itself under `/data/adb/ksu/bin/busybox` (consistent
`mount`/`nsenter`/`cut` regardless of mksh+toybox), and if it isn't in init's
mount namespace it re-execs through `nsenter -t 1 -m`, so it works the same
from `adb shell`, Termux, or any app's `su`.

### sshd

In `/data/adb/nixchroot/config`: `SSHD=1`, `SSHD_PORT=8022`,
`SSHD_LISTEN=127.0.0.1` (or `0.0.0.0` for Wi-Fi). Put keys in
`/data/adb/nixchroot/authorized_keys`. Host keys are generated on first start
(`ssh-keygen -A`), key-only root login, no PAM.

```sh
adb forward tcp:8022 tcp:8022 && ssh -p 8022 root@127.0.0.1
```

sshd started by the module runs under ksud, not under an app, so the
Android 12+ phantom process killer won't reap it (it *will* reap things you
background from Termux).

## What the nixchroot module does

`/data/adb/nixchroot/config` (created from `config.default`, survives module
updates):

| stage | action |
|---|---|
| `post-fs-data.sh` (blocking, before zygote, init mount ns) | self-bind `$NIXROOT` and `--make-private` it; `proc` (fresh instance, no Android `hidepid`), bind `/sys`, bind `/dev`, bind `/dev/pts`, tmpfs `/tmp` (1777) and `/run`, tmpfs `/dev/shm` + `/dev/fd`, `/dev/std*` links (`DEV_EXTRAS=1`), write `/etc/resolv.conf` from `DNS=` |
| `service.sh` (late_start) | re-assert the above; background: wait for `sys.boot_completed` and first unlock, bind `SDCARD_SRC` → `/mnt/sdcard`, start sshd if enabled |
| `action.sh` (manager "Action" button) | no rootfs: download + verify + extract + mount (`bootstrap.sh`); otherwise re-apply and print status |
| `uninstall.sh` | unmount only; never deletes the rootfs |

Every mount checks `/proc/self/mountinfo` first, so all stages are
idempotent and re-runnable; nothing is persistent across reboot except files
on `/data`. If no rootfs is present the module does nothing.

Namespaces: KernelSU runs module scripts from ksud in init's (global) mount
namespace, so these mounts are visible to `adb shell` and to anything that
`nsenter -t 1 -m`'s. KernelSU's `su` from an app, by contrast, runs in that
app's namespace (KernelSU elevates the calling process in place); use
`su -M`/`--mount-master` or just let `nixroot` nsenter for you. The chroot is
made a private mount so `/proc`, `/dev` binds etc. don't propagate into
the zygote/app namespaces through `/data`'s shared peer group.

`/dev/shm` and `/dev/fd` are created in Android's real `/dev` (a tmpfs) because
the chroot's `/dev` is a bind of it. Set `DEV_EXTRAS=0` if that bothers you.

## mitm-cacert module (Android 14/15)

Since Android 14 the system trust store is the Conscrypt APEX
(`/apex/com.android.conscrypt/cacerts`), updatable via Mainline, read-only,
and `/apex` mounts are private per mount namespace. Zygote and every app have
their own namespace, so overlaying `/system/etc/security/cacerts` (the
classic module approach) or binding in init's namespace does nothing for
apps.

What the module does, in `service.sh`:

1. Waits for `/apex/com.android.conscrypt/cacerts`.
2. Builds a **per-boot** stage dir `/data/adb/mitmca/stage-<boot_id>/apex`:
   copies the current APEX roots, adds your `certs.d/*.0`, `chown 0:0`, 644,
   `chcon u:object_r:system_security_cacerts_file:s0` (if apps can't read the
   dir, Conscrypt fails closed and *every* TLS connection in the app breaks).
   Same for `/system/etc/security/cacerts` if `LEGACY_SYSTEM_STORE=1`.
   The stage is never modified once mounted (deleting a bind source's files
   deletes them in every namespace); old boots' stages are removed.
3. `nsenter -t <pid> -m -- busybox mount -o bind <stage> /apex/com.android.conscrypt/cacerts`
   into init, `zygote`, `zygote64`, `webview_zygote`, every `*_zygote`
   (app zygotes), and every distinct mount namespace among already-running
   zygote children/grandchildren (system_server, apps, USAPs, isolated
   services). Dedupe is by `/proc/<pid>/ns/mnt` inode; idempotent via a
   sentinel cert check inside each namespace.
4. Repeats after `sys.boot_completed`, then (`WATCH=1`) polls the zygote PID
   set every `WATCH_INTERVAL` s and re-injects if zygote restarts.

Apps forked after the zygote injection inherit it. Changing `certs.d`
needs a reboot (by design, see 2).

```sh
# mitmproxy on your laptop
nix run .#mitm-ca-prep -- ~/.mitmproxy/mitmproxy-ca-cert.pem
# mitmproxy inside the chroot (CA lives in the chroot's /root/.mitmproxy)
nixroot mitmdump              # first start generates ~/.mitmproxy (Ctrl-C)
su -c 'sh /data/adb/modules/mitm-cacert/mitmca-add /data/local/nix/root/.mitmproxy/mitmproxy-ca-cert.pem'
adb reboot
# verify: KernelSU manager → mitm-cacert → Action, or
su -c 'nsenter -t $(pidof zygote64) -m -- ls /apex/com.android.conscrypt/cacerts/ | grep <hash>'
```

Caveats: this makes every app on the device trust your CA, so only do it on a
lab phone. Apps that pin certs, ship their own store (Flutter/BoringSSL,
Firefox unless "third-party CAs" is enabled, some Cronet builds) or use mTLS
still need Frida/objection. The bind shows up in `/proc/self/mountinfo` of
every app, which root/MITM detectors look for.

## Interception (shared network stack)

The chroot shares Android's network namespace, so mitmproxy's transparent
mode gets `SO_ORIGINAL_DST` directly. From the Android side (as root),
redirecting one app's traffic by UID:

```sh
APP_UID=$(stat -c %u /data/data/com.target.app)
iptables -t nat -A OUTPUT -p tcp -m owner --uid-owner $APP_UID --dport 443 -j REDIRECT --to-ports 8080
iptables -t nat -A OUTPUT -p tcp -m owner --uid-owner $APP_UID --dport 80  -j REDIRECT --to-ports 8080
# block QUIC so it falls back to TCP
iptables  -A OUTPUT -p udp -m owner --uid-owner $APP_UID --dport 443 -j REJECT
ip6tables -A OUTPUT -p udp -m owner --uid-owner $APP_UID --dport 443 -j REJECT
nixroot mitmproxy --mode transparent --showhost
```

mitmproxy runs as uid 0, so it is not caught by its own `--uid-owner` rule.
Remove rules with `-D` (netd won't clean up rules it doesn't own).

## Frida

`frida-server` stays on the **Android side** (it needs Android's linker,
ART, and the real `/system` to inject into zygote/app processes; a glibc
chroot can't host it). Push the matching build:

```sh
nixroot lab-frida-version        # e.g. 17.x.y
# download frida-server-<ver>-android-arm64.xz, unxz, push to /data/local/tmp
su -c '/data/local/tmp/frida-server -l 127.0.0.1:27042 &'
nixroot frida-ps -H 127.0.0.1:27042      # alias in the chroot: frida-ps-local
```

Versions must match exactly. `-U` (USB) doesn't make sense from inside the
chroot; use `-H`. Over USB from your laptop, `adb forward tcp:27042 tcp:27042`.

## Samsung / Android 15 / One UI 7 quirks

- **No Nix sandbox.** `sandbox = false`, `filter-syscalls = false`,
  `build-users-group =` (single-user). The Nix sandbox needs user/mount/pid
  namespaces + `pivot_root` from a context SELinux lets do that; even where
  the GKI 5.10 kernel has `CONFIG_USER_NS`, Samsung's policy and the su
  domain make it a dead end (`zcat /proc/config.gz | grep -E 'USER_NS|PID_NS'`
  to see what you have). Builds on the phone are therefore unsandboxed and
  impure-ish; substitute instead of building where you can.
- **DEFEX / PROCA / RKP.** If your KernelSU is the LKM on Samsung's stock GKI
  kernel, or a Samsung-source kernel with KernelSU patched in, Samsung's
  DEFEX is still in the kernel. Symptoms: root processes killed or getting
  `EPERM` on `setuid`/`execve` with nothing in the SELinux audit log, often
  `defex` lines in `dmesg`. sshd's privsep `setuid` and Nix's builders are the
  usual victims. Fixes: a kernel built with `CONFIG_SECURITY_DEFEX` off (and
  `CONFIG_PROCA` off), or the KernelSU-provided GKI image (which is Google's
  GKI and has none of Samsung's security add-ons, but check that your vendor
  modules load with it before relying on it). RKP/uH isn't what breaks
  chroots, but it is why patching the kernel at runtime is not an option.
- **SELinux.** KernelSU's `su` domain (`u:r:su:s0`) gets a permissive-style
  allow set, and processes in the chroot inherit it, so no relabeling of
  `/data/local/nix` is needed. `nixroot --status` prints the context and the
  label of `$NIXROOT` (usually inherited from `/data/local`, e.g.
  `system_data_file`). If something gets `avc: denied` (`dmesg | grep avc`),
  check whether it was started from a different domain (e.g. from an app
  without going through su). `setenforce 0` is a quick way to tell DEFEX
  from SELinux: if it still fails while permissive, it's DEFEX. Don't
  `restorecon -R` the chroot; don't put it under `/data/local/tmp`
  (`shell_data_file`, and things clean it).
- **KernelSU module mounting.** Neither module relies on KernelSU's
  `system/` overlay for anything important; all mounts are done by the
  scripts. `system/bin/nixroot` is shipped for convenience, but newer KernelSU
  releases delegate module mounting to a "metamodule"; without one,
  `/system/bin/nixroot` won't appear, so use
  `/data/adb/modules/nixchroot/nixroot`. KernelSU's per-app **"Umount
  modules"** (the default for apps not granted root) unmounts KernelSU's own
  module mounts in those apps; the CA binds are ordinary binds from `/data`,
  not KernelSU module mounts, so they survive. If a future KernelSU starts
  matching them, grant the target app a profile with umount disabled.
- **Android 15 storage.** `/data/local` is protected by the device-encrypted
  (DE) key, so the chroot is mountable in post-fs-data before unlock;
  `/storage/emulated/0` (FUSE) and `/data/media/0` (CE) only exist after the
  first unlock, which is why the sdcard bind waits. On the Flip4 `/data` is
  f2fs; Nix's SQLite db is fine on it.
- **DNS.** Android has no `/etc/resolv.conf` and the chroot's glibc can't
  talk to netd's resolver, so Private DNS / per-network DNS settings don't
  apply inside. The module writes `DNS=` servers. On a captive or
  DNS-filtered Wi-Fi, set `DNS` to the network's resolver.
- **Paranoid networking.** If a non-root user in the chroot can't open
  sockets, it needs group `aid_inet` (3003) / `aid_net_raw` (3004); those
  groups are already in `/etc/group` and root/sshd are members.
- **No 16 KB page issue.** Android 15 introduced 16 KB page devices; the
  Flip4 is 4 KB pages, so nixpkgs' aarch64 binaries run as-is.
- **Auto Blocker** (One UI 6+) blocks USB commands, including `adb install`
  and sometimes `adb shell` from unknown hosts. Turn it off on the lab phone.
- **Seccomp.** KernelSU clears the seccomp filter when it elevates, so the
  app seccomp filter doesn't follow you into the chroot even when entering
  from an app's `su`. If you ever see `SIGSYS`, enter via `adb shell` to
  rule it out.

## Troubleshooting

| symptom | check |
|---|---|
| `nixroot: no rootfs at /data/local/nix` | install didn't extract; `ls /data/local/nix/nix/var/nix/profiles` |
| mounts missing after boot | `cat /data/adb/nixchroot/nixchroot.log`; module enabled in KernelSU manager? `nixroot --mount` |
| `nixroot` works over adb but not from Termux | you're in the app's mount ns without nsenter; `su -M -c nixroot` |
| `error: getting status of /nix/store/...` / Nix thinks paths are invalid | db not loaded: `touch /data/local/nix/.nix-db-pending`, re-enter |
| `nix build` fails with `cloning builder process: Operation not permitted` | sandbox got re-enabled (e.g. a user nix.conf); `nix show-config \| grep sandbox` |
| sshd exits immediately | `nixroot /nix/var/nix/profiles/default/bin/sshd -d -p 8023` (foreground debug); `dmesg \| grep -iE 'defex\|avc'` |
| TLS breaks in **all** apps after mitm-cacert | stage not readable: `ls -Z /data/adb/mitmca/stage-*/apex \| head`; look for `avc` on `system_security_cacerts_file`; disable module + reboot |
| CA not trusted in one app | `nsenter -t <app pid> -m -- ls /apex/com.android.conscrypt/cacerts \| grep <hash>`; if present, it pins or has its own store |
| `frida` can't connect | version mismatch (`lab-frida-version`), server listening on the right address, or SELinux denial on the server |
| `unable to resolve host` in chroot | `/etc/resolv.conf` got clobbered; `nixroot --remount` rewrites it |
| deleting the rootfs | **reboot first** (or `nixroot --umount` and check `nixroot --status` shows no mounts). `rm -rf` with `/dev` and `/sys` bound inside it will happily recurse into them |

## Layout

```
flake.nix  flake.lock
nix/lab-env.nix          toolset
nix/rootfs-tree.nix      /etc, profile links, dirs (target pkgs)
nix/rootfs.nix           closureInfo + tar + pigz (build-host pkgs)
nix/ksu-module.nix       module.prop templating, deterministic zip
rootfs/etc/              passwd group nix.conf sshd_config profile ...
modules/nixchroot/       common.sh post-fs-data.sh service.sh action.sh uninstall.sh customize.sh config.default
modules/mitm-cacert/     common.sh service.sh action.sh mitmca-add customize.sh uninstall.sh config.default
scripts/nixroot          enter script (also shipped in the module)
scripts/install.sh       host/on-device installer
scripts/push-modules.sh  ksud module install over adb
scripts/mitm-ca-prep.sh  CA -> <subject_hash_old>.0
```
