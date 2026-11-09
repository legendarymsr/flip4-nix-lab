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
  # nixpkgs' apktool wraps Google's prebuilt aapt/aapt2, which is only published
  # for x86_64-linux/darwin. On aarch64 we feed it a static aapt2 (and aapt)
  # from lzhiyong/android-sdk-tools 35.0.2 — see nix/aapt-aarch64.nix.
  aaptAarch64 = import ./aapt-aarch64.nix { inherit pkgs; };
  apktool = pkgs.apktool.override { aapt = aaptAarch64; };

  # mitmproxy 12.3.0's test_emudhra drives the client side of the handshake with
  # stdlib ssl.SSLContext. CPython 3.14+ (python/cpython#160040) hard-rejects the
  # compromised eMudhra intermediate SPKI that --emudhra deliberately uses, so
  # the test fails on every arch with X509_V_ERR_CERT_REJECTED. Upstream
  # mitmproxy#8568 (commit 992052ee, in main / post-12.3.1) rewrites the test to
  # use mitmproxy's own OpenSSL stack on both sides; apply that patch and run
  # the full suite with no tests disabled.
  mitmproxy = pkgs.mitmproxy.overridePythonAttrs (o: {
    patches = (o.patches or [ ]) ++ [
      ../patches/mitmproxy-8568-emudhra-avoid-stdlib-ssl.patch
    ];
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
    apktool
    aaptAarch64     # aapt + aapt2 on PATH for apktool b / manual use
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
