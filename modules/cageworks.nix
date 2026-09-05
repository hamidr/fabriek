## cageworks NixOS module: the factories a machine declares and how they are
## supervised, plus the two programs that run them.
##
## It requires nixcage's own module, which owns everything about a cage: the
## workspace roots, the container layer, the VM on macOS, and the uid range a
## role's number is allocated from. Nothing here builds a session; it declares
## what several named workers sharing one repository are, and calls nixcage
## when one of them needs somewhere to work (ADR-018).
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.cageworks;
  cageworks = import ./package.nix { inherit pkgs; };
in
{
  options.cageworks = {
    factories = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            repository = lib.mkOption {
              type = lib.types.str;
              example = "/home/me/Src/acme";
              description = "The one git repository this factory works.";
            };
            workflows = lib.mkOption {
              type = lib.types.attrsOf (
                lib.types.submodule {
                  options = {
                    stages = lib.mkOption {
                      type = lib.types.listOf (
                        lib.types.submodule {
                          options = {
                            needs = lib.mkOption {
                              type = lib.types.str;
                              example = "build";
                              description = ''
                                The capability this stage needs. Any role whose
                                provides includes it may take this stage's
                                tasks, so a column in the flow and a worker are
                                declared separately and capacity is added by
                                declaring a role rather than by editing the
                                pipeline.
                              '';
                            };
                            ready = lib.mkOption {
                              type = lib.types.listOf lib.types.str;
                              default = [ ];
                              example = [ "acceptance" ];
                              description = ''
                                The fields a task must carry before this stage
                                will take it. Checked for presence and nothing
                                else, so nothing anyone wrote is read. Empty
                                means the acceptance criteria alone.
                              '';
                            };
                            done = lib.mkOption {
                              type = lib.types.nullOr lib.types.str;
                              default = null;
                              example = "tests pass and the change is reviewable";
                              description = ''
                                What finishing means at this stage, in your own
                                words. Handed to the role in its brief and never
                                enforced: judging whether work meets a bar is
                                reading content, which belongs in a cage.
                              '';
                            };
                            fanOut = lib.mkOption {
                              type = lib.types.bool;
                              default = false;
                              description = ''
                                Whether this stage may produce several tasks
                                for the next one rather than a single task.
                              '';
                            };
                            gate = lib.mkOption {
                              type = lib.types.nullOr lib.types.str;
                              default = null;
                              description = "Name of the gate that stops a run at this stage.";
                            };
                          };
                        }
                      );
                      default = [ ];
                      description = ''
                        The stages this workflow runs, in order. A list rather
                        than a graph, so a pipeline cannot contain a cycle and
                        every stage is reachable from the first.
                      '';
                    };
                    budget = lib.mkOption {
                      type = lib.types.submodule {
                        options = {
                          runs = lib.mkOption {
                            type = lib.types.ints.unsigned;
                            default = 0;
                            description = ''
                              How many runs this workflow may start. Zero is
                              unbounded. Runs are what can be counted from
                              outside a cage whatever agent a role runs, which
                              is why they are the measure that always applies.
                            '';
                          };
                          tokens = lib.mkOption {
                            type = lib.types.ints.unsigned;
                            default = 0;
                            description = ''
                              How many tokens this workflow may spend, where
                              the agent reports them. Zero is unbounded. This
                              bounds a workflow in addition to its runs, never
                              instead of them.
                            '';
                          };
                        };
                      };
                      default = { };
                      description = "What this workflow may spend before it stops.";
                    };
                    consults = lib.mkOption {
                      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
                      default = { };
                      example = {
                        builder = [ "architect" ];
                      };
                      description = ''
                        Who may ask whom, keyed by the asking role. Unlike the
                        pipeline this may point backwards, because the role
                        that can answer a question is usually the one before.
                        A consult creates a leaf task, so no chain of roles
                        waiting on each other can close into a loop.
                      '';
                    };
                  };
                }
              );
              default = { };
              description = "The pipelines this factory can run.";
            };
            roles = lib.mkOption {
              type = lib.types.attrsOf (
                lib.types.submodule {
                  options = {
                    provides = lib.mkOption {
                      type = lib.types.listOf lib.types.str;
                      default = [ ];
                      example = [ "build" ];
                      description = ''
                        The capabilities this role can work. A stage names one
                        of these rather than naming a role, so several roles can
                        work one stage at once. A role providing none takes no
                        work.
                      '';
                    };
                    command = lib.mkOption {
                      type = lib.types.nullOr (lib.types.listOf lib.types.str);
                      default = null;
                      example = [ "claude" ];
                      description = ''
                        What this role's session runs. Which coding agent that
                        is belongs to the declaration, never to cageworks. Unset
                        means the ordinary session shell.
                      '';
                    };
                    shell = lib.mkOption {
                      type = lib.types.nullOr lib.types.str;
                      default = null;
                      example = "backend-jvm";
                      description = ''
                        The devShell of the project's own flake this role works
                        in, so a specialist brings its own toolchain: a JVM
                        specialist and a frontend specialist work one repository
                        with different tools. Unset means the project's default
                        environment. A session refuses to start when the project
                        does not define the named shell.
                      '';
                    };
                  };
                }
              );
              default = { };
              description = "The roles that work this factory, one worktree and one uid each.";
            };
          };
        }
      );
      default = { };
      description = ''
        Factories declared on this machine (PRD-003). Each assigns one
        repository to a set of roles. Requires nixcage.principalUidRange, from
        which each role's uid is allocated.
      '';
    };

    supervisor = lib.mkOption {
      type = lib.types.submodule {
        options = {
          concurrency = lib.mkOption {
            type = lib.types.ints.unsigned;
            default = 0;
            example = 3;
            description = ''
              How many agent sessions may run at once on this machine, across
              every factory. Zero is unbounded. Note that one worktree per role
              already bounds active runs by the number of declared roles, so a
              cap at or above that count constrains nothing.
            '';
          };
          taskAttempts = lib.mkOption {
            type = lib.types.ints.positive;
            default = 3;
            description = ''
              How many attempts a task may have before it stops becoming runs.
              A task that fails for a reason no retry can fix would otherwise
              consume a whole workflow one attempt at a time.
            '';
          };
          runTimeoutSeconds = lib.mkOption {
            type = lib.types.ints.positive;
            default = 3600;
            description = ''
              How long a single run may take. Past this it is cancelled and
              counted as a failed attempt, so a hung agent costs one attempt
              rather than a slot held until someone notices.
            '';
          };
          roleQuota = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "20G";
            description = ''
              How much a single role's worktree may hold, as a ZFS size. It
              bounds what one agent can write: a build loop that fills the
              volume otherwise stops every other role and the supervisor with
              it. Null leaves a role bounded only by what nixcage's storage
              sits on, and is what a machine without a pool always gets.
            '';
          };
        };
      };
      default = { };
      description = "How a factory is supervised. Absent unless one is declared.";
    };
  };

  config = lib.mkMerge [
    {
      environment.systemPackages = [
        cageworks.cli
        cageworks.container
      ];

      ## Rendered only when a factory is declared: nothing else reads it, and
      ## the guest program refuses to run without it.
      environment.etc."cageworks/supervisor" = lib.mkIf (cfg.factories != { }) {
        text = ''
          TASK_MAX_ATTEMPTS=${toString cfg.supervisor.taskAttempts}
          TASK_TIMEOUT_SECONDS=${toString cfg.supervisor.runTimeoutSeconds}
          RUN_CONCURRENCY=${toString cfg.supervisor.concurrency}
          ROLE_QUOTA=${lib.optionalString (cfg.supervisor.roleQuota != null) cfg.supervisor.roleQuota}
        '';
      };
    }

    ## The declaration is rendered as a directory tree: the guest reads a value
    ## by reading a file, which needs no parser and cannot confuse one value
    ## with its neighbour. A role directory exists even when the role declares
    ## no command, because the directory is what says the role was declared.
    {
      environment.etc = lib.mkMerge (
        lib.concatLists (
          lib.mapAttrsToList (
            factoryName: factory:
            [
              { "cageworks/factories/${factoryName}/repository".text = factory.repository + "\n"; }
            ]
            ++ lib.mapAttrsToList (roleName: role: {
              "cageworks/factories/${factoryName}/roles/${roleName}/declared".text = "";
            }) factory.roles
            ++ lib.mapAttrsToList (
              roleName: role:
              lib.mkIf (role.command != null) {
                ## One word per line: a command is argv, never a shell line, so
                ## nothing in it is re-split or expanded by anything.
                "cageworks/factories/${factoryName}/roles/${roleName}/command".text =
                  lib.concatMapStrings (word: word + "\n") role.command;
              }
            ) factory.roles
            ++ lib.mapAttrsToList (
              roleName: role:
              lib.mkIf (role.provides != [ ]) {
                "cageworks/factories/${factoryName}/roles/${roleName}/provides".text =
                  lib.concatMapStrings (c: c + "\n") role.provides;
              }
            ) factory.roles
            ++ lib.mapAttrsToList (
              roleName: role:
              lib.mkIf (role.shell != null) {
                ## Just the name: the toolchain itself is the project's, and
                ## cageworks only carries which of its shells this role enters.
                "cageworks/factories/${factoryName}/roles/${roleName}/shell".text = role.shell + "\n";
              }
            ) factory.roles
                      ++ lib.concatLists (
            lib.mapAttrsToList (
              workflowName: workflow:
              (lib.imap0 (i: stage: {
                "cageworks/factories/${factoryName}/workflows/${workflowName}/stages/${
                  lib.fixedWidthNumber 2 i
                }/needs".text = stage.needs + "\n";
              }) workflow.stages)
              ++ (lib.imap0 (
                i: stage:
                lib.mkIf (stage.ready != [ ]) {
                  "cageworks/factories/${factoryName}/workflows/${workflowName}/stages/${
                    lib.fixedWidthNumber 2 i
                  }/ready".text = lib.concatMapStrings (f: f + "\n") stage.ready;
                }
              ) workflow.stages)
              ++ (lib.imap0 (
                i: stage:
                lib.mkIf (stage.done != null) {
                  "cageworks/factories/${factoryName}/workflows/${workflowName}/stages/${
                    lib.fixedWidthNumber 2 i
                  }/done".text = stage.done + "\n";
                }
              ) workflow.stages)
              ++ (lib.imap0 (
                i: stage:
                lib.mkIf stage.fanOut {
                  "cageworks/factories/${factoryName}/workflows/${workflowName}/stages/${
                    lib.fixedWidthNumber 2 i
                  }/fanout".text = "";
                }
              ) workflow.stages)
              ++ (lib.imap0 (
                i: stage:
                lib.mkIf (stage.gate != null) {
                  "cageworks/factories/${factoryName}/workflows/${workflowName}/stages/${
                    lib.fixedWidthNumber 2 i
                  }/gate".text = stage.gate + "\n";
                }
              ) workflow.stages)
              ++ lib.concatLists (
                lib.mapAttrsToList (
                  asker: targets:
                  map (target: {
                    "cageworks/factories/${factoryName}/workflows/${workflowName}/consults/${asker}/${target}".text =
                      "";
                  }) targets
                ) workflow.consults
              )
              ++ [
                {
                  "cageworks/factories/${factoryName}/workflows/${workflowName}/budget-runs".text =
                    toString workflow.budget.runs + "\n";
                  "cageworks/factories/${factoryName}/workflows/${workflowName}/budget-tokens".text =
                    toString workflow.budget.tokens + "\n";
                }
              ]
            ) factory.workflows
          )
          ) cfg.factories
        )
      );

      ## A factory whose roles have no uid range cannot give them identities,
      ## and the range is nixcage's to hand out from (ADR-018).
      assertions = lib.mapAttrsToList (name: _: {
        assertion = config.nixcage.principalUidRange != null;
        message = "cageworks.factories.${name} needs nixcage.principalUidRange";
      }) cfg.factories;
    }
  ];
}
