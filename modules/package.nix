## The two programs cageworks ships, built from the scripts at the repository
## root rather than from strings inside a Nix expression.
##
## Both are ordinary shell files so that shellcheck reads them and the bats
## suite drives them directly. That is what makes the seam with nixcage
## something the suite asserts on rather than something it crosses: a test
## stubs nixcage-container on PATH and records the argv it was given.
{ pkgs, self }:
let
  ## Everything the guest program sources, plus the guidance it binds into a
  ## role's session. One directory so the program needs a single path rather
  ## than one per file.
  lib' = pkgs.runCommand "cageworks-lib" { } ''
    mkdir -p $out
    cp ${../modules/names.sh} $out/names.sh
    cp ${../modules/role-worktree.sh} $out/role-worktree.sh
    cp ${../modules/factory-clone.sh} $out/factory-clone.sh
    cp ${../modules/factory-config.sh} $out/factory-config.sh
    cp ${../modules/schema.sh} $out/schema.sh
    cp ${../modules/sizes.sh} $out/sizes.sh
    cp ${../modules/resources.sh} $out/resources.sh
    cp ${../modules/repo-declaration.sh} $out/repo-declaration.sh
    cp ${../modules/operator-config.sh} $out/operator-config.sh
    cp ${../modules/machine.sh} $out/machine.sh
    cp ${../modules/task-store.sh} $out/task-store.sh
    cp ${../modules/workflow-config.sh} $out/workflow-config.sh
    cp ${../modules/record.sh} $out/record.sh
    cp ${../modules/caps.sh} $out/caps.sh
    cp ${../modules/signing.sh} $out/signing.sh
    cp ${../modules/integrate.sh} $out/integrate.sh
    cp ${../modules/role-guidance.sh} $out/role-guidance.sh
    cp ${../modules/machine-spec.sh} $out/machine-spec.sh
    cp ${../modules/machine-plan.sh} $out/machine-plan.sh
    cp ${../modules/forge.sh} $out/forge.sh
    cp ${../modules/bus.sh} $out/bus.sh
    cp ${../modules/role-guidance.md} $out/role-guidance.md
  '';

  ## The guest program, on the machine the cages are on. It calls
  ## nixcage-container, which is on the same machine and installed by nixcage's
  ## own module, so nothing is pinned here beyond what runs beside it.
  container = pkgs.stdenv.mkDerivation {
    pname = "cageworks-container";
    version = "1.0.0";
    src = ../cageworks-container;
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.makeWrapper ];
    buildInputs = [ pkgs.bash ];
    installPhase = ''
      mkdir -p $out/bin
      substitute $src $out/bin/cageworks-container --replace-fail '@lib@' '${lib'}'
      chmod +x $out/bin/cageworks-container
      wrapProgram $out/bin/cageworks-container \
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
              ## The shared record (ADR-022). Every call to it is retried and
              ## bounded, which is what coreutils' timeout above is for
              ## (ADR-024).
              git-bug
              ## Reading the declaration out of a factory's clone, and shaping
              ## the JSON it comes back as (ADR-020).
              nix
              jq
              ## Preparing the forge: its API, and its own CLI on the
              ## machine's path (guest/board.nix wraps it).
              curl
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
    pname = "cageworks";
    version = "1.0.0";
    src = ../cageworks;
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.makeWrapper ];
    buildInputs = [ pkgs.bash ];
    installPhase = ''
      mkdir -p $out/bin
      substitute $src $out/bin/cageworks \
        --replace-fail '@lib@' '${lib'}' \
        --replace-fail '@self@' '${self}'
      chmod +x $out/bin/cageworks
      wrapProgram $out/bin/cageworks \
        --prefix PATH : ${
          pkgs.lib.makeBinPath (
            with pkgs;
            [
              coreutils
              ## Reporting a role's state to a console that may not be
              ## running. Both are best effort and neither stops a session.
              jq
              netcat
              ## The operator's config is TOML and nix parses it, which is one
              ## dependency rather than two: nix is already what reads a
              ## repository's declaration (ADR-020).
              nix
              ## A key per factory's machine, made here because cageworks owns
              ## the way into a machine it built (ADR-019).
              openssh
            ]
          )
        }
    '';
  };
in
{
  inherit container cli lib';
}
