{
  description = "CoralNPU development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Provides mkEdaShell (the EDA devshell builder)
    lowrisc-nix.url = "github:lowRISC/lowrisc-nix";
  };

  outputs = { self, nixpkgs, lowrisc-nix }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
      };

      fhsEnv = pkgs.buildFHSEnv {
        name = "coralnpu-env";
        targetPkgs = p: with p; [
          bazelisk
          (writeShellScriptBin "bazel" ''exec ${bazelisk}/bin/bazelisk "$@"'')
          git
          clang
          llvmPackages.bintools
          gcc
          gnumake
          binutils
          python3
          zlib
          ncurses
          openssl
          libxml2
          curl
          unzip
          zip
          which
          file
          perl
          patch
          diffutils
          findutils
          gnused
          gawk
          coreutils
          z3
          lz4
        ];
        extraOutputsToInstall = ["dev"];
        profile = ''
          export CC=clang
          export CXX=clang++
          export C_INCLUDE_PATH=/usr/include
          export LIBRARY_PATH=/lib
          export CPLUS_INCLUDE_PATH=/usr/include
        '';
        runScript = "bash";
      };
    in {
      devShells.${system} = rec {
        default = fhs;
        fhs = fhsEnv.env;
        hdl = pkgs.mkShell {
          packages = with pkgs; [ 
            yosys
            gnumake
            verilator
            python3
            z3
            lz4
            zlib
            pkg-config
            re2
            abseil-cpp
            (bender.overrideAttrs (old: {
              postPatch =
                (old.postPatch or "")
                + ''
                  substituteInPlace crates/bender-slang/build.rs \
                    --replace-fail '("SLANG_USE_MIMALLOC", "1")' '("SLANG_USE_MIMALLOC", "0")'
                '';
            }))
          ];
          env = {
            UVM_HOME=pkgs.fetchFromGitHub {
              owner = "chipsalliance";
              repo = "uvm-verilator";
              tag = "uvm-2020-3.2";
              hash = "sha256-BjFOVynkgW6ngIpz20CgRaNtN7ikWeVULD2kdC7nMHM=";
            };
          };
        };
        pydot = pkgs.mkShell {
          packages = with pkgs; [
            graphviz
            python3
          ];
        };
        linter = pkgs.mkShell {
          packages = with pkgs; [
            verible
            metals
          ];
        };
        eda = lowrisc-nix.lib.mkEdaShell {
          inherit pkgs;
          name = "coral-EDA";
          tools = [
            {
              "name" = "Verdi";
              "vendor" = "Synopsys";
              "version" = "X-2025.06-SP2-1";
              "comment" = "Provides the FSDB dumper (novas) libraries VCS loads to dump waves in FSDB format.";
            }
            {
              "name" = "VCS";
              "vendor" = "Synopsys";
              "version" = "X-2025.06-SP2-1";
              "comment" = "RTL simulator.";
            }
          ];
          extraPkgs = with pkgs; [
            gnumake
          ];
          extraDeps = [];
          profile =''
            export NOVAS_HOME=$VERDI_HOME
          '';
        };
      };
      packages.${system}.default = fhsEnv;
    };
}
