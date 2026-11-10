# Flip4 Nix Lab companion APK, built without Gradle: aapt2 (resources +
# manifest), kotlinc, R8 (dex + shrink the Kotlin stdlib), zipalign.
# Everything is pinned by flake.lock, so the unsigned APK is reproducible.
# Output:
#   flip4-nix-lab-<v>-unsigned.apk   reproducible, aligned, unsigned
#   flip4-nix-lab-<v>-debug.apk      signed with a key generated during the build
#                                    (throwaway; release builds are signed with
#                                    scripts/sign-apk.sh, see README)
{ nixpkgs, system, version, versionCode, assets }:
let
  inherit (import ./android-sdk.nix { inherit nixpkgs system; }) pkgs sdkRoot;
  bt = "${sdkRoot}/build-tools/35.0.0";
  androidJar = "${sdkRoot}/platforms/android-35/android.jar";
  jdk = pkgs.jdk21_headless;
  src = ../companion;
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "flip4-nix-lab-companion";
  inherit version;
  inherit src;
  nativeBuildInputs = [ pkgs.kotlin jdk pkgs.zip pkgs.unzip ];
  dontConfigure = true;
  buildPhase = ''
    runHook preBuild
    export HOME=$TMPDIR
    mkdir -p build/assets build/dex
    ${pkgs.lib.concatStringsSep "\n" (pkgs.lib.mapAttrsToList (n: f: "cp ${f} build/assets/${n}") assets)}

    ${bt}/aapt2 compile --dir res -o build/res.zip
    ${bt}/aapt2 link -I ${androidJar} --manifest AndroidManifest.xml \
      --version-code ${toString versionCode} --version-name ${version} \
      -A build/assets -0 zip -o build/base.apk build/res.zip

    kotlinc src -cp ${androidJar} -jvm-target 17 -no-reflect -nowarn -d build/classes.jar
    java -cp ${bt}/lib/d8.jar com.android.tools.r8.R8 --release --min-api 30 \
      --lib ${androidJar} --pg-conf proguard.pro --output build/dex \
      build/classes.jar ${pkgs.kotlin}/lib/kotlin-stdlib.jar

    # deterministic zip entry for classes.dex
    touch -d '1980-01-01 00:00:00' build/dex/classes.dex
    (cd build/dex && TZ=UTC zip -X -q -9 ../base.apk classes.dex)
    ${bt}/zipalign -P 16 -f 4 build/base.apk build/unsigned.apk
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp build/unsigned.apk $out/flip4-nix-lab-${version}-unsigned.apk
    keytool -genkeypair -keystore build/debug.jks -storepass android -keypass android \
      -alias debug -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=flip4-nix-lab debug" -noprompt 2>/dev/null
    ${bt}/apksigner sign --ks build/debug.jks --ks-pass pass:android \
      --out $out/flip4-nix-lab-${version}-debug.apk build/unsigned.apk
    rm -f $out/*.idsig
    runHook postInstall
  '';
  passthru = { inherit sdkRoot; };
}
