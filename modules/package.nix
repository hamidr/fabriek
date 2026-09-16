## The two programs fabriek ships, built from the scripts at the repository
## root rather than from strings inside a Nix expression.
##
## Both are ordinary shell files so that shellcheck reads them and the bats
## suite drives them directly. That is what makes the seam with nixcage
## something the suite asserts on rather than something it crosses: a test
## stubs nixcage-container on PATH and records the argv it was given.
{ pkgs, self }:
let
  ## Everything the machine program sources. One directory so the program
  ## needs a single path rather than one per file.
  ## Every module rather than a list of them: the list drifted twice (check.sh,
  ## transcript.sh) and the installed CLI was what found out.
  lib' = pkgs.runCommand "fabriek-lib" { } ''
    mkdir -p $out
    cp ${
      pkgs.lib.fileset.toSource {
        root = ../modules;
        fileset = pkgs.lib.fileset.fileFilter (f: f.hasExt "sh") ../modules;
      }
    }/* $out/
  '';

  ## The machine program, on the machine the cages are on. It calls
  ## nixcage-container, which is on the same machine and installed by nixcage's
  ## own module, so nothing is pinned here beyond what runs beside it.
  container = pkgs.stdenv.mkDerivation {
    pname = "fabriek-container";
    version = "1.0.0";
    src = ../fabriek-container;
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.makeWrapper ];
    buildInputs = [ pkgs.bash ];
    installPhase = ''
      mkdir -p $out/bin
      substitute $src $out/bin/fabriek-container --replace-fail '@lib@' '${lib'}'
      chmod +x $out/bin/fabriek-container
      wrapProgram $out/bin/fabriek-container \
        --prefix PATH : ${
          pkgs.lib.makeBinPath (
            with pkgs;
            [
              coreutils
              ## A role's worktree is made here and handed to its uid: git
              ## makes the worktree, setfacl grants the uid the parts of the
              ## repository it needs without a shared group, which a cage
              ## cannot have (ADR-010).
              git
              acl
              ## A role's worktree is indexed here before it is handed over
              ## (ADR-049), so the role's first session finds the graph
              ## built.
              (import ./codegraph { inherit pkgs; })
              ## Reading the declaration out of a factory's clone, and shaping
              ## the JSON it comes back as (ADR-020).
              nix
              jq
              ## Preparing the forge and speaking to the executor: the
              ## forge's API, the bus, and the forge's own CLI on the
              ## machine's path (machine/board.nix wraps it).
              curl
              valkey
              "/run/current-system/sw"
            ]
          )
        }
    '';
  };

  ## What an operator types. Its only dependency is the nixcage CLI, which
  ## carries a command to the machine the cages are on, and which the operator
  ## has installed already because it is what declares their cages.
  cli = pkgs.stdenv.mkDerivation {
    pname = "fabriek";
    version = "1.0.0";
    src = ../fabriek;
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.makeWrapper ];
    buildInputs = [ pkgs.bash ];
    installPhase = ''
      mkdir -p $out/bin
      substitute $src $out/bin/fabriek \
        --replace-fail '@lib@' '${lib'}' \
        --replace-fail '@self@' '${self}'
      chmod +x $out/bin/fabriek
      ## The TUI types its commands at this program by path (console).
      wrapProgram $out/bin/fabriek \
        --set-default FABRIEK_CLI $out/bin/fabriek \
        --prefix PATH : ${
          pkgs.lib.makeBinPath (
            with pkgs;
            [
              coreutils
              ## What the shell modules reach for beside coreutils: awk and
              ## sed over the runner's files, grep, xargs for the machine's
              ## argv, setsid to detach the runner and perl where setsid
              ## is absent. A unit on a NixOS host has no PATH but this one
              ## (measured 2026-09-16: "awk: command not found" from the
              ## pc's unit).
              ## bash by name: the share daemons' wrappers are run as text
              ## under a bash the runner's directory does not name.
              bash
              gawk
              gnused
              gnugrep
              findutils
              perl
              jq
              ## The operator's checkout is read with git: its origin, its
              ## pin, its declaration at the commit (ADR-020, ADR-032).
              git
              ## The operator's config is TOML and nix parses it, which is one
              ## dependency rather than two: nix is already what reads a
              ## repository's declaration (ADR-020).
              nix
              ## A key per factory's machine, made here because fabriek owns
              ## the way into a machine it built (ADR-019).
              openssh
              ## The TUI (ADR-039 point 3), which factory console execs.
              (import ../factory { inherit pkgs; }).package
            ]
            ++ pkgs.lib.optional pkgs.stdenv.hostPlatform.isLinux pkgs.util-linux
          )
        }
    '';
  };
in
{
  inherit container cli lib';
}
