{
  inputs = {
    nixpkgs = {
      # url = "github:nixos/nixpkgs";
      url = "nixpkgs/nixos-unstable";
    };
    flake-utils = {
      url = "github:numtide/flake-utils";
    };
  };

  outputs = { self, nixpkgs, flake-utils }:
    # flake-utils.lib.eachDefaultSystem
    # nix develop .#devShell.i686-linux
    flake-utils.lib.eachSystem ["x86_64-linux" "i686-linux"] (system:
      let pkgs = nixpkgs.legacyPackages.${system};
          t    = pkgs.lib.trivial;
          hl   = pkgs.haskell.lib;

          stdenv = pkgs.stdenv;

          # hpkgs = pkgs.haskell.packages.ghc925;
          hpkgs = pkgs.haskell.packages.ghc965;

          nativeDeps = [
            pkgs.libffi
            pkgs.gmp
            pkgs.zlib
          ];

      in {
        devShell = pkgs.mkShell {

          buildInputs = nativeDeps;

          nativeBuildInputs = [
            # pkgs.haskell.packages.ghc902.ghc

            # pkgs.haskell.packages.ghc9101.ghc
            # hpkgs.ghc
            hpkgs.alex
            hpkgs.happy

            pkgs.gcc
            pkgs.libgccjit
            pkgs.ncurses
            pkgs.automake
            pkgs.autoconf
            pkgs.libiconv
            pkgs.binutils
            pkgs.coreutils

            pkgs.python3
            # pkgs.sphinx

            # hpkgs.haskell-language-server
            # hpkgs.hlint
          ] ++ map (x: if builtins.hasAttr "dev" x then x.dev else x) nativeDeps;

          # LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath nativeDeps;

          RUNNING_UNDER_NIX = "1";

          LIBRARY_PATH =
            "${pkgs.lib.makeLibraryPath nativeDeps}:${pkgs.lib.makeLibraryPath [stdenv.cc.cc pkgs.glibc]}:${pkgs.lib.getLib pkgs.libgccjit}/lib/gcc/${stdenv.hostPlatform.config}/${pkgs.lib.getVersion stdenv.cc.cc}";


          # # Add executable packages to the nix-shell environment.
          # packages = [
          #   # hpkgs.ghc
          #   # hpkgs.cabal-install
          #   pkgs.zlib
          # ];

          # Add build dependencies of the listed derivations to the nix-shell environment.
          # inputsFrom = [ pkgs.hello pkgs.gnutar ];

          # ... - everything mkDerivation has
        };
      });
}
