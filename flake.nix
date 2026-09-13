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
          factory = import ./factory { inherit pkgs; };
        in
        {
          packages = {
            default = cageworks.cli;
            cageworks = cageworks.cli;
            ## The TypeScript half: executor, extension, decider, relay, TUI.
            factory = factory.package;
          }
          ## The machine program runs on the machine the cages are on, which on
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
              git
              ## A machine's key is made with ssh-keygen (ADR-019).
              openssh
              ## The TypeScript package (ADR-034): compiled with tsc and
              ## tested with node's own runner, so nothing is fetched.
              nodejs
              typescript
              ## The system harness (tests/system) runs the factory on this
              ## host with scripted actors: the bus and the forge for real,
              ## on localhost. Forgejo is marked broken on Darwin in nixpkgs,
              ## so a Mac gets Gitea, whose API and CLI are the subset the
              ## forge modules use; the machine itself always runs Forgejo.
              valkey
              curl
              (if stdenv.hostPlatform.isDarwin then gitea else forgejo)
            ];

            BATS_LIB_PATH = "${pkgs.bats.libraries.bats-support}/share/bats:${pkgs.bats.libraries.bats-assert}/share/bats";

            shellHook = ''
              export PATH="$PWD:$PATH"
              ## pi's types, linked in from the store rather than fetched;
              ## the same directory the package build uses.
              ln -sfn ${factory.nodeModules} "$PWD/factory/node_modules"
            '';
          };

          formatter = pkgs.nixfmt-rfc-style;
        };

      flake.overlays.default = final: _prev: {
        cageworks =
          (import ./modules/package.nix {
            pkgs = final;
            inherit (inputs) self;
          }).cli;
        cageworks-container =
          (import ./modules/package.nix {
            pkgs = final;
            inherit (inputs) self;
          }).container;
      };

      ## One factory's machine, built from a spec the operator's side composes.
      ## A function rather than a nixosConfigurations attribute because how big
      ## a machine is and what port it answers on are not facts this repository
      ## can know (ADR-019).
      flake.lib.machine = import ./modules/vm.nix {
        inherit (inputs)
          nixpkgs
          microvm
          nixcage
          self
          ;
      };

      ## One factory's machine from the repository it works, which is what a
      ## generated machine flake calls (ADR-040). The declaration is validated
      ## and clamped in a build, and each role's devShell is realised there.
      flake.lib.factory = import ./modules/factory.nix {
        inherit (inputs)
          nixpkgs
          microvm
          nixcage
          self
          ;
      };
    };
}
