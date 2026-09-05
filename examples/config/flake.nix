## A machine that runs a factory. Copy the cageworks parts of this into the
## configuration flake that already declares your cages -- on macOS that is the
## VM flake nixcage's own template makes at ~/.config/nixcage, and on Linux it
## is the host's NixOS configuration.
##
## Two modules, because there are two things: nixcage owns the cages, the
## workspace roots and the uid range a role's number is allocated from;
## cageworks owns the factories and how they are supervised (ADR-018).
{
  description = "A machine running a cageworks factory";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixcage.url = "github:hamidr/nixcage";
    cageworks = {
      url = "github:hamidr/cageworks";
      inputs.nixcage.follows = "nixcage";
    };
  };

  outputs =
    {
      nixpkgs,
      nixcage,
      cageworks,
      ...
    }:
    {
      nixosConfigurations.example = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ## On macOS this is nixcage.nixosModules.nixcage instead: the cages
          ## run in the shared VM, and that module carries its configuration.
          nixcage.nixosModules.host
          cageworks.nixosModules.cageworks

          {
            nixcage = {
              workspaceRoots = [ "/home/me/Src" ];

              ## The range a role's uid comes from. Roles are principals of
              ## nixcage's: it hands out the numbers and never reissues one, so
              ## a new role cannot inherit a dead one's files. It must not
              ## overlap any account that already exists here.
              principalUidRange = {
                base = 700000;
                size = 64;
              };

              ## Where nixcage keeps its state, if this host has a dataset for
              ## it. Set it and each role's worktree becomes a dataset of its
              ## own, which is what makes roleQuota below able to bind
              ## anything. Left unset everything still works, unbounded
              ## (ADR-017).
              # storage.dataset = "tank/nixcage";
            };

            cageworks = {
              supervisor = {
                ## A task that keeps failing stops instead of consuming the
                ## whole factory, and a run that hangs costs one attempt.
                taskAttempts = 3;
                runTimeoutSeconds = 3600;
                ## How many agent sessions may run at once on this machine.
                ## Zero is unbounded; one worktree per role already bounds
                ## active runs by the number of declared roles.
                concurrency = 3;
                ## What one role's worktree may hold. A role that runs out
                ## fails on its own instead of stopping the whole factory.
                roleQuota = "20G";
              };

              factories.acme = {
                ## The repository this factory works. Roles never touch it
                ## directly: cageworks clones it onto nixcage's own storage and
                ## syncs the two, so this may live wherever you keep your
                ## projects (ADR-011).
                repository = "/home/me/Src/acme";

                ## A command is argv, one word per element, never a shell line.
                ## Which coding agent a role runs is yours to say; a role that
                ## names none gets the ordinary session shell.
                ##
                ## 'shell' names one devShell of the repository's own flake, so
                ## each specialist has its own tools to hand. What is in that
                ## shell is the repository's business -- flake-parts is the
                ## usual way to write several (ADR-016).
                ##
                ## 'provides' is what a role can work. A stage names a
                ## capability rather than a role, so declaring a second backend
                ## adds capacity without touching the pipeline (ADR-015).
                roles = {
                  architect = {
                    command = [ "claude" ];
                    provides = [ "design" ];
                  };
                  backend = {
                    command = [ "claude" ];
                    provides = [ "build" ];
                    shell = "backend-jvm";
                  };
                  frontend = {
                    command = [ "claude" ];
                    provides = [ "build" ];
                    shell = "frontend";
                  };
                  reviewer = {
                    command = [ "claude" ];
                    provides = [ "review" ];
                  };
                };

                ## A stage says what the work needs, what a task must carry
                ## before it is taken, and what finishing means there. The last
                ## is prose: the role reads it, cageworks never checks it.
                workflows.ship = {
                  stages = [
                    {
                      needs = "design";
                      done = "the approach is written down and the work is split";
                    }
                    {
                      needs = "build";
                      ready = [ "acceptance" ];
                      done = "tests pass and the change is reviewable";
                    }
                    {
                      needs = "review";
                      gate = "before-integration";
                    }
                  ];

                  ## What this workflow may spend before it stops. Runs are
                  ## what can be counted from outside a cage whatever agent a
                  ## role runs, which is why they always apply.
                  budget.runs = 200;

                  ## Who may ask whom. Unlike the pipeline this may point
                  ## backwards, because the role that can answer a question is
                  ## usually the one before.
                  consults.backend = [ "architect" ];
                };
              };
            };
          }
        ];
      };
    };
}
