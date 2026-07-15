{
  lib,
  pkgs,
  zigPackages,
  stdenv,
}:
zigPackages.makePackage {
  pname = "site-exporter";
  version = "0.1.0";

  src = ../.;

  nativeBuildInputs = with pkgs; [
    libpq
    libpq.dev
    zlib
    icu
    openssl
  ];

  zigReleaseMode = "fast";
  depsHash = "sha256-niKPok6HvjtlS1QJICsHJU+GvJ5lj9sy28ur1Aob2iA=";
}
