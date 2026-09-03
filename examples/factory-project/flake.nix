## Example flake for a repository a factory works. Still an ordinary flake --
## nixcage needs nothing project-specific -- but it defines one devShell per
## specialist instead of a single default. A role declared with
## 'shell = "backend-jvm"' enters the shell of that name; a role that names
## none enters 'default'.
##
## flake-parts is used because it makes several per-system shells readable;
## plain 'devShells = forAllSystems ...' produces the same attributes.
{
  description = "Example repository worked by a nixcage factory";

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
