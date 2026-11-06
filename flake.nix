{
  description = "CoralNPU development environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
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
          zlib.dev
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
        ];
        profile = ''
          export CC=clang
          export CXX=clang++
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
      };
      packages.${system}.default = fhsEnv;
    };
}
