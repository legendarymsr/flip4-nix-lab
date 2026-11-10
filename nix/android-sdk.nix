# Minimal Android SDK for building the companion APK without Gradle:
# aapt2 + d8/r8 (build-tools) + android.jar (platform 35) + lint (cmdline-tools).
{ nixpkgs, system, withLint ? false, withEmulator ? false }:
let
  pkgs = import nixpkgs {
    inherit system;
    config = { android_sdk.accept_license = true; allowUnfree = true; };
  };
  sdk = pkgs.androidenv.composeAndroidPackages {
    buildToolsVersions = [ "35.0.0" ];
    platformVersions = [ "35" ];
    includeEmulator = withEmulator;
    includeSystemImages = withEmulator;
    systemImageTypes = [ "default" ];
    abiVersions = [ "x86_64" ];
    includeNDK = false;
    includeSources = false;
    cmdLineToolsVersion = "latest";
    toolsVersion = null;
  };
in
{ inherit pkgs; androidsdk = sdk.androidsdk; sdkRoot = "${sdk.androidsdk}/libexec/android-sdk"; }
