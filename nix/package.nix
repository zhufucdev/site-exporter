{
  lib,
  pkgs,
  zig,
  stdenv,
}:
stdenv.mkDerivation {
  pname = "site-exporter";
  version = "0.1.0";

  src = ../.;

  nativeBuildInputs =
    with pkgs;
    [
      libpq
      libpq.dev
      zlib
      icu
      openssl
    ]
    ++ [ zig.hook ];

  preBuild = ''
    cp -r ${pkgs.callPackage ./deps.nix { }} $ZIG_GLOBAL_CACHE_DIR/p
    chmod 744 -R $ZIG_GLOBAL_CACHE_DIR/p
  '';

  # zigBuildFlags = "--zig-lib-dir ${pkgs.callPackage ./deps.nix { }}";
}
