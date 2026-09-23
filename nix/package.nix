{
  callPackage,
  lib,
  stdenv,
  zig_0_16,
}:

let
  zig_deps = callPackage ./zig-deps.nix { };
  is_linux = stdenv.hostPlatform.isLinux;
in
stdenv.mkDerivation {
  pname = "rush";
  version = "0.1.0";
  src = ../.;

  strictDeps = true;
  dontInstall = true;

  nativeBuildInputs = [ zig_0_16.hook ];

  postConfigure = ''
    # Cache paths appear in the static library's debug information.
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
  '';

  buildPhase = ''
    runHook preBuild

    TERM=dumb zig build \
      --system ${zig_deps} \
      ${lib.optionalString is_linux "-Dtarget=native-native-musl"} \
      -Doptimize=ReleaseSafe \
      -Dregister-shell=false \
      --prefix "$out"

    runHook postBuild
  '';

  passthru = {
    inherit zig_deps;
    shellPath = "/bin/rush";
  };

  meta = {
    description = "rockorager's user-friendly shell";
    homepage = "https://github.com/rockorager/rush";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
    license = lib.licenses.mit;
    mainProgram = "rush";
  };
}
