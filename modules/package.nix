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

  ## The machine program, on the host the cages are on (ADR-067). It calls
  ## nixcage-container, which is on the same host and installed by nixcage's
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
              ## host's path (host/board.nix wraps it).
              curl
              ## The bus is one nats-server for the host (ADR-069): the
              ## CLI where a shell asks it anything, and the server itself
              ## because prepare checks the configuration before it asks
              ## for a reload.
              natscli
              nats-server
              ## up holds a lock on the factory's directory for its whole
              ## run (ADR-067, models/factory-lifecycle.qnt).
              util-linux
              "/run/current-system/sw"
            ]
          )
        }
    '';
  };

  ## What an operator types. It reaches the machine program on this host
  ## through sudo (ADR-067), and reads the operator's config and checkout
  ## itself.
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
      wrapProgram $out/bin/fabriek \
        --prefix PATH : ${
          pkgs.lib.makeBinPath (
            with pkgs;
            [
              coreutils
              ## What the shell modules reach for beside coreutils. A unit
              ## on a NixOS host has no PATH but this one (measured
              ## 2026-09-16: "awk: command not found" from a unit).
              bash
              gawk
              gnused
              gnugrep
              findutils
              jq
              ## The operator's checkout is read with git: its pin, its
              ## declaration at the commit, and the factory's branches
              ## fetched into it (ADR-020, ADR-067).
              git
              ## The operator's config is TOML and nix parses it, which is one
              ## dependency rather than two: nix is already what reads a
              ## repository's declaration (ADR-020).
              nix
            ]
          )
        }
    '';
  };
in
{
  inherit container cli lib';
}
