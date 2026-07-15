{
  description = "A Nix-flake-based Zig development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, ... }@inputs:

    let
      overlays = [
        (final: prev: {
          zigpkgs = inputs.zig.packages.${prev.system};
        })
      ];
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forEachSupportedSystem =
        f:
        inputs.nixpkgs.lib.genAttrs supportedSystems (
          system:
          f {
            inherit system;
            pkgs = import inputs.nixpkgs {
              inherit system overlays;
            };
          }
        );
    in
    {
      devShells = forEachSupportedSystem (
        { pkgs, system }:
        {
          default = pkgs.mkShellNoCC {
            packages = with pkgs; [
              zigPackages."0.16"
              zls
              lldb
              self.formatter.${system}
            ];

            nativeBuildInputs = with pkgs; [
              libpq
              libpq.dev
              zlib
              icu
              openssl
            ];

            shellHook = ''
              export LIBRARY_PATH=${pkgs.zlib.out}/lib:${pkgs.icu.out}/lib:${pkgs.openssl.out}/lib:${pkgs.libpq.out}/lib:${pkgs.libpq.dev}/lib:$LIBRARY_PATH
              export PATH=${pkgs.libpq.dev}/include:$PATH
            '';
          };
        }
      );

      formatter = forEachSupportedSystem ({ pkgs, ... }: pkgs.nixfmt);
    };
}
