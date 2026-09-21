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
          fabriek = import ./modules/package.nix {
            inherit pkgs;
            inherit (inputs) self;
          };
          factory = import ./factory { inherit pkgs; };
        in
        {
          packages = {
            default = fabriek.cli;
            fabriek = fabriek.cli;
            ## The TypeScript half: executor, extension, decider, relay, TUI.
            factory = factory.package;
          }
          ## The machine program runs on the host the cages are on, which is
          ## a NixOS host (ADR-067). It is not offered on darwin at all: it
          ## needs setfacl, and acl does not build there.
          // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            fabriek-container = fabriek.container;
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
              ## up's lock is flock(1): util-linux's on Linux, and on a Mac
              ## the one package that ports it.
              (if stdenv.hostPlatform.isDarwin then flock else util-linux)
            ];

            BATS_LIB_PATH = "${pkgs.bats.libraries.bats-support}/share/bats:${pkgs.bats.libraries.bats-assert}/share/bats";

            shellHook = ''
              export PATH="$PWD:$PATH"
              ## pi's types, linked in from the store rather than fetched;
              ## the same directory the package build uses.
              ln -sfn ${factory.nodeModules} "$PWD/factory/node_modules"
            '';
          };

          formatter = pkgs.nixfmt;
        };

      flake.overlays.default = final: _prev: {
        fabriek =
          (import ./modules/package.nix {
            pkgs = final;
            inherit (inputs) self;
          }).cli;
        fabriek-container =
          (import ./modules/package.nix {
            pkgs = final;
            inherit (inputs) self;
          }).container;
        ## The TypeScript half, for the loop the floor carries (ADR-035)
        ## and the executor, the decider and the relay beside it.
        fabriek-factory = (import ./factory { pkgs = final; }).package;
        ## The language-server extension every role's pi directory loads
        ## (ADR-043), and the codegraph tools beside it (ADR-049).
        pi-lsp = import ./modules/pi-lsp { pkgs = final; };
        pi-codegraph = import ./modules/pi-codegraph { pkgs = final; };
      };

      ## A NixOS host declares its factories: the operator's file, and per
      ## factory its services (ADR-048, ADR-067). The repository and the
      ## nixpkgs it pins are what render evaluates a role's profile from.
      flake.nixosModules.host = import ./modules/host.nix { inherit (inputs) self nixpkgs; };

      ## What a role can be: the shipped catalogue and a repository's own,
      ## composed into one derivation per role (ADR-042).
      flake.lib.catalogue = import ./modules/catalogue.nix { inherit (inputs) self; };
    };
}
