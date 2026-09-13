## Example flake for a repository a factory works.
##
## Two things make it one. It declares the factory itself, as the 'fabriek'
## output (ADR-020), so the team that works this repository travels with it
## rather than living in one person's machine configuration. And it defines one
## devShell per part of the project instead of a single default, because a
## role declared with 'shell = "backend-jvm"' enters the shell of that name; a
## role that names none enters 'default'.
##
## The declaration is kept in ./fabriek.nix beside this file so that reading
## it costs nothing: anything checking it can evaluate that file alone, without
## this flake's inputs. Who a role is, its specialists, is not here either: it
## is fabriek's catalogue and this repository's own under ./fabriek/catalogue
## (ADR-042), named from fabriek.nix.
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
        {
          ## What this project needs to build itself, per part, against this
          ## flake's own nixpkgs. A role's specialists bring the rest: the
          ## editor's tools, the language's linters and runners, the skills.
          ## A devShell here is what a person entering this repository on
          ## their own machine would use, and nothing fabriek-specific.
          devShells = {
            ## A role that declares no shell lands here.
            default = pkgs.mkShell { packages = [ ]; };

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
          };
        };
    };
}
