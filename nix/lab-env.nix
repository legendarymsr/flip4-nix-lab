# The lab toolset, as one buildEnv that becomes /nix/var/nix/profiles/default
# inside the chroot. `pkgs` is an aarch64-linux package set (native or cross).
{ pkgs }:
let
  inherit (pkgs) lib;

  python = pkgs.python3.withPackages (ps: with ps; [
    frida-python      # same frida as frida-tools; must match frida-server on the Android side
    androguard
    pwntools
    cryptography
    pycryptodome
    requests
    httpx
    websockets
    protobuf
    lxml
    pyyaml
    rich
    ipython
    capstone
    keystone-engine
    unicorn
    lief
    pyelftools
    construct
    hexdump
    scapy
    rzpipe
  ]);

  # Prints the frida version the chroot speaks, i.e. the frida-server build you
  # need to push to the Android side (frida-server-<ver>-android-arm64).
  # nixpkgs' apktool puts Google's prebuilt aapt/aapt2 on PATH, and that is
  # x86_64-linux/darwin only. Decoding (`apktool d`) doesn't need aapt2, so keep
  # apktool and drop aapt; for `apktool b` pass `--aapt /path/to/aarch64-aapt2`
  # or rebuild the APK on your laptop.
  apktool = pkgs.apktool.override { aapt = pkgs.emptyDirectory; };

  # At the pinned rev the aarch64 mitmproxy isn't in the binary cache because
  # its test suite fails: test_tlsconfig.py::test_emudhra (2 cases, a
  # cert-chain-vs-trust-store fixture, unrelated to the arch). Everything else
  # passes (1829 tests under qemu); skip those two.
  mitmproxy = pkgs.mitmproxy.overridePythonAttrs (o: {
    disabledTests = (o.disabledTests or [ ]) ++ [ "test_emudhra" ];
  });

  lab-frida-version = pkgs.writeShellScriptBin "lab-frida-version" ''
    exec ${python}/bin/python3 -c 'import frida; print(frida.__version__)'
  '';

  core = with pkgs; [
    nix
    bashInteractive
    bash-completion
    coreutils
    findutils
    gnugrep
    gnused
    gawk
    gnutar
    gzip
    xz
    zstd
    unzip
    zip
    which
    less
    file
    procps
    util-linux
    iproute2
    ncurses       # terminfo for whatever $TERM your terminal sends
    cacert
    openssh
    openssl
    curl
    git
    tmux
    vim
    strace
  ];

  lab = with pkgs; [
    frida-tools
    mitmproxy
    jadx
    apktool          # decode-only on aarch64, see above
    dex2jar
    rizin
    android-tools  # adb/fastboot; `adb connect 127.0.0.1:5555` for on-device adbd over TCP
    tcpdump
    nmap
    socat
    sqlite
    binwalk
    gdb
    python
    lab-frida-version
  ];
in
pkgs.buildEnv {
  name = "flip4-lab-env";
  paths = core ++ lab;
  pathsToLink = [ "/bin" "/sbin" "/lib" "/libexec" "/share" "/etc" ];
  extraOutputsToInstall = [ "man" ];
  ignoreCollisions = true; # python wrappers vs. frida-tools/mitmproxy share some script names
}
