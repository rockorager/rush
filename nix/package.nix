{ pkgs }:

let
  src = ../.;
  pname = "rush";
  version = "0.1.0";
  cache = pkgs.stdenvNoCC.mkDerivation {
    inherit version src;

    pname = "${pname}-cache";

    dontInstall = true;
    nativeBuildInputs = with pkgs; [ zig_0_16 ];

    buildPhase = ''
      mkdir -p $out/tmp
      export ZIG_GLOBAL_CACHE_DIR=$out
      zig build --fetch --summary none
    '';

    # Failing this hash means the dependencies changed and it needs to be updated
    outputHash = "sha256-Rpb0dEtm6Yq+5/Mg3RWvVzLH46NC1o/QvZL7jLYS9Vs=";
    outputHashMode = "nar";
  };
  isLinux = pkgs.stdenv.hostPlatform.isLinux;
in
pkgs.stdenv.mkDerivation {
  inherit pname version src;

  dontInstall = true;
  nativeBuildInputs = with pkgs; [ zig_0_16 ];
  passthru = {
    inherit cache;
    shellPath = "/bin/rush";
  };

  buildPhase = ''
    export ZIG_GLOBAL_CACHE_DIR=$TEMP
    ln -sf ${cache}/p $ZIG_GLOBAL_CACHE_DIR/p
    zig build ${pkgs.lib.optionalString isLinux "-Dtarget=native-native-musl"} \
      -Doptimize=ReleaseSafe \
      -Dregister-shell=false \
      --prefix $out
  '';

  meta = with pkgs.lib; {
    description = "rockorager's user-friendly shell";
    homepage = "https://github.com/rockorager/rush";
    platforms = with platforms; linux ++ darwin;
    license = licenses.mit;
    mainProgram = "rush";
  };
}
