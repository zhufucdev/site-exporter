{
  pkgs,
  zig,
  stdenv,
}:
let
  deps = pkgs.callPackage ./deps.nix { };
in
stdenv.mkDerivation {
  pname = "site-exporter";
  version = "0.1.0";
  meta.mainProgram = "site_exporter";

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
    cp -r ${deps} $ZIG_GLOBAL_CACHE_DIR/p
    chmod 744 -R $ZIG_GLOBAL_CACHE_DIR/p
  '';
  zigBuildFlags = "--system ${deps}";
}
