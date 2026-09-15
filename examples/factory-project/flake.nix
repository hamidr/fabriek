## Example flake for a repository a factory works.
##
## The factory itself is not here: it is ./fabriek.toml beside this file
## (ADR-020, ADR-058), a file of data that needs no flake to be read. What
## this flake gives the factory is one devShell per part of the project
## instead of a single default, because a role declared with
## 'shell = "backend-jvm"' enters the shell of that name; a role that names
## none enters 'default'. Who a role is, its specialists, is not here
## either: it is fabriek's catalogue and this repository's own under
## ./fabriek/catalogue (ADR-042), named from fabriek.toml.
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

      perSystem =
        { pkgs, ... }:
        {
          ## What this project needs to build itself, per part, against this
          ## flake's own nixpkgs. A role's specialists bring the rest: the
          ## editor's tools, the language's linters and runners, the skills.
          ## A devShell here is what a person entering this repository on
          ## their own machine would use, and nothing fabriek-specific.
          devShells = {
            ## A role that declares no shell lands here: the architect, the
            ## manager and the reviewer, who read and run the suite but build
            ## nothing. The project is Python, so this is what runs it.
            default = pkgs.mkShell {
              packages = with pkgs; [
                python3
                python3Packages.pytest
              ];
            };

            ## The builder's shell: the suite's runner and the JVM the
            ## springboot specialist's kit expects a project to carry.
            backend-jvm = pkgs.mkShell {
              packages = with pkgs; [
                python3
                python3Packages.pytest
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
