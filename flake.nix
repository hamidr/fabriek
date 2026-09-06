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
          cageworks = import ./modules/package.nix { inherit pkgs; };
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
            ];

            BATS_LIB_PATH = "${pkgs.bats.libraries.bats-support}/share/bats:${pkgs.bats.libraries.bats-assert}/share/bats";

            shellHook = ''
              export PATH="$PWD:$PATH"
            '';
          };

          formatter = pkgs.nixfmt-rfc-style;
        };

      flake.overlays.default = final: _prev: {
        cageworks = (import ./modules/package.nix { pkgs = final; }).cli;
        cageworks-container = (import ./modules/package.nix { pkgs = final; }).container;
      };

    };
}
