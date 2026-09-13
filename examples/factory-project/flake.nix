## Example flake for a repository a factory works.
##
## Two things make it one. It declares the factory itself, as the 'fabriek'
## output (ADR-020), so the team that works this repository travels with it
## rather than living in one person's machine configuration. And it defines one
## devShell per specialist instead of a single default, because a role declared
## with 'shell = "backend-jvm"' enters the shell of that name; a role that names
## none enters 'default'.
##
## The declaration is kept in ./fabriek.nix beside this file so that reading
## it costs nothing: anything checking it can evaluate that file alone, without
## this flake's inputs.
##
## flake-parts is used because it makes several per-system shells readable;
## plain 'devShells = forAllSystems ...' produces the same attributes.
{
  description = "Example repository worked by a fabriek factory";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      ## Who works this repository. fabriek reads exactly this attribute, out
      ## of the commit rather than the working tree, so an edit here takes
      ## effect when it is committed.
      flake.fabriek = import ./fabriek.nix;

      perSystem =
        { pkgs, ... }:
        let
          ## What every role in this repository gets, whichever shell it names.
          ##
          ## Composed rather than inherited, because devShells do not compose:
          ## a role declaring shell = "backend-jvm" enters that shell and only
          ## that shell, so anything left in 'default' alone would be invisible
          ## to it. This list is concatenated into each one below, which is the
          ## whole mechanism -- there is no fabriek field for it, and a field
          ## would resolve package names against a nixpkgs this flake does not
          ## pin.
          ##
          ## The agent is not here. Every cage carries pi as its floor whatever
          ## this file says (ADR-030), so a repository cannot produce a role
          ## that fails to start by forgetting it. Naming a build of pi here
          ## stays allowed: a role's profile sits on the front of PATH, so it
          ## shadows the machine's.
          common = with pkgs; [
            jq
            ripgrep
          ];

          ## A role's own tools, on top of what every role gets.
          specialist = packages: pkgs.mkShell { packages = common ++ packages; };
        in
        {
          devShells = {
            ## A role that declares no shell lands here, so this is the common
            ## set and nothing else.
            default = specialist [ ];

            backend-jvm = specialist (with pkgs; [
              jdk21
              maven
            ]);

            frontend = specialist (with pkgs; [
              nodejs_22
              pnpm
            ]);

            data-analyst = specialist (with pkgs; [
              duckdb
              python3
            ]);

            devops = specialist (with pkgs; [
              kubectl
              terraform
            ]);
          };
        };
    };
}
