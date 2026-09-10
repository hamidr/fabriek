{
  description = "A factory of named roles working one repository, each in a cage of its own";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    ## The cages. Pinned from its own remote rather than taken as a path
    ## input: a path input would make the two one repository again with extra
    ## steps, and there would be no version for the interface to break at
    ## (ADR-018).
    nixcage = {
      url = "github:hamidr/nixcage";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    ## The machine a factory runs in is cageworks' now, so what builds one is
    ## an input of ours rather than something reached through nixcage
    ## (ADR-019).
    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem =
        { pkgs, lib, ... }:
        let
          cageworks = import ./modules/package.nix {
            inherit pkgs;
            inherit (inputs) self;
          };
        in
        {
          packages = {
            default = cageworks.cli;
            cageworks = cageworks.cli;
          }
          ## The guest program runs on the machine the cages are on, which on
          ## macOS is the VM and never this one. It is not offered here at
          ## all: it needs setfacl, and acl does not build on darwin.
          // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            cageworks-container = cageworks.container;
          };

          devShells.default = pkgs.mkShell {
            buildInputs = with pkgs; [
              bash
              jq
              shellcheck
              bats
              bats.libraries.bats-support
              bats.libraries.bats-assert
              ## The record is git-bug (ADR-013), and the tests drive it for
              ## real rather than stubbing it, so it belongs in the shell.
              git
              git-bug
              ## A machine's key is made with ssh-keygen (ADR-019).
              openssh
            ];

            BATS_LIB_PATH = "${pkgs.bats.libraries.bats-support}/share/bats:${pkgs.bats.libraries.bats-assert}/share/bats";

            shellHook = ''
              export PATH="$PWD:$PATH"
            '';
          };

          formatter = pkgs.nixfmt-rfc-style;
        };

      flake.overlays.default = final: _prev: {
        cageworks = (import ./modules/package.nix {
          pkgs = final;
          inherit (inputs) self;
        }).cli;
        cageworks-container = (import ./modules/package.nix {
          pkgs = final;
          inherit (inputs) self;
        }).container;
      };


      ## One factory's machine, built from a spec the operator's side composes.
      ## A function rather than a nixosConfigurations attribute because how big
      ## a machine is and what port it answers on are not facts this repository
      ## can know (ADR-019).
      flake.lib.machine = import ./modules/vm.nix {
        inherit (inputs) nixpkgs microvm nixcage self;
      };
    };
}
