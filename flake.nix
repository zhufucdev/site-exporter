{
  description = "A Nix-flake-based Zig development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
      ...
    }@inputs:

    let
      overlay = (
        final: prev: {
          site-exporter = final.callPackage (import ./nix/package.nix) { };
        }
      );
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      nixpkgsFor = forAllSystems (
        system:
        import inputs.nixpkgs {
          inherit system;
          overlays = [ overlay ];
          config = {
            allowUnsupportedSystem = true;
          };
        }
      );
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgsFor.${system};
        in
        {
          default = pkgs.mkShellNoCC {
            packages = with pkgs; [
              zigPackages."0.16"
              zls
              lldb
            ];

            nativeBuildInputs = self.packages.${system}.default.nativeBuildInputs;

            shellHook = ''
              export LIBRARY_PATH=${pkgs.zlib.out}/lib:${pkgs.icu.out}/lib:${pkgs.openssl.out}/lib:${pkgs.libpq.out}/lib:${pkgs.libpq.dev}/lib:$LIBRARY_PATH
              export PATH=${pkgs.libpq.dev}/include:$PATH
            '';
          };
        }
      );

      packages = forAllSystems (system: {
        default = nixpkgsFor.${system}.site-exporter;
      });

      nixosModules.default = { ... }: {
        nixpkgs.overlays = [ overlay ];
        imports = [ ./nix/module.nix ];
      };
    };
}
