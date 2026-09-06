## Example flake for a repository a factory works.
##
## Two things make it one. It declares the factory itself, as the 'cageworks'
## output (ADR-020), so the team that works this repository travels with it
## rather than living in one person's machine configuration. And it defines one
## devShell per specialist instead of a single default, because a role declared
## with 'shell = "backend-jvm"' enters the shell of that name; a role that names
## none enters 'default'.
##
## The declaration is kept in ./cageworks.nix beside this file so that reading
## it costs nothing: anything checking it can evaluate that file alone, without
## this flake's inputs.
##
## flake-parts is used because it makes several per-system shells readable;
## plain 'devShells = forAllSystems ...' produces the same attributes.
{
  description = "Example repository worked by a cageworks factory";

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

      ## Who works this repository. cageworks reads exactly this attribute, out
      ## of the commit rather than the working tree, so an edit here takes
      ## effect when it is committed.
      flake.cageworks = import ./cageworks.nix;

      perSystem =
        { pkgs, ... }:
        {
          devShells = {
            ## What every role needs regardless of speciality. A role that
            ## declares no shell lands here.
            default = pkgs.mkShell {
              packages = with pkgs; [
                git
                jq
              ];
            };

            backend-jvm = pkgs.mkShell {
              packages = with pkgs; [
                jdk21
                maven
              ];
            };

            frontend = pkgs.mkShell {
              packages = with pkgs; [
                nodejs_22
                pnpm
              ];
            };

            data-analyst = pkgs.mkShell {
              packages = with pkgs; [
                duckdb
                python3
              ];
            };

            devops = pkgs.mkShell {
              packages = with pkgs; [
                kubectl
                terraform
              ];
            };
          };
        };
    };
}
