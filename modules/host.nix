## nixcage host module for Linux: project containers run directly on this
## machine, so there is no VM. Renders /etc/nixcage/config for the CLI and
## installs the same container layer the VM uses. Secrets come from the
## host's own sops-nix setup under /run/secrets.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.nixcage;
  container = import ./container.nix { inherit pkgs; };
in
{
  options.nixcage = {
    workspaceRoots = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      example = [ "/home/me/Src" ];
      description = ''
        Absolute directories whose flake subdirectories can be entered.
        Containers bind only their own project subdirectory.
      '';
    };

    secretEnv = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        ANTHROPIC_API_KEY = "anthropic";
      };
      description = ''
        Environment variable to sops secret name mapping. Each container
        session gets the variable set from this host's /run/secrets/<name>.
      '';
    };

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
                            role = lib.mkOption {
                              type = lib.types.str;
                              description = "The role that owns this stage.";
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
                    command = lib.mkOption {
                      type = lib.types.nullOr (lib.types.listOf lib.types.str);
                      default = null;
                      example = [ "claude" ];
                      description = ''
                        What this role's session runs. Which coding agent that
                        is belongs to the declaration, never to nixcage. Unset
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
        repository to a set of roles. Requires supervisor.roleUidRange.
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
          roleUidRange = lib.mkOption {
            type = lib.types.nullOr (
              lib.types.submodule {
                options = {
                  base = lib.mkOption {
                    type = lib.types.ints.unsigned;
                    example = 700000;
                    description = "First uid a factory role may be allocated.";
                  };
                  size = lib.mkOption {
                    type = lib.types.ints.positive;
                    default = 64;
                    description = "How many uids the range covers.";
                  };
                };
              }
            );
            default = null;
            description = ''
              The uid range factory roles are allocated from (ADR-010). A role
              keeps its number, and a forgotten role's number is never
              reissued, so a new role cannot inherit a dead one's files. The
              range must not overlap accounts that already exist here.
            '';
          };
        };
      };
      default = { };
      description = "Factory supervision. Absent unless a factory is declared.";
    };

    git = lib.mkOption {
      type = lib.types.submodule {
        options = {
          userName = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "Ada Lovelace";
            description = "Committer name every session uses. No identity is rendered unless both this and userEmail are set.";
          };
          userEmail = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "ada@example.org";
            description = "Committer email every session uses.";
          };
          signing.enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Sign commits and tags through the ssh-agent the CLI forwards
              into the session. No key material is copied in, and a session
              entered without a reachable agent simply fails to sign.
            '';
          };
        };
      };
      default = { };
      description = "Git identity and signing for container sessions.";
    };
  };

  config = lib.mkMerge [
    {
    environment.systemPackages = [ container.script ];

    ## Rendered only when an identity exists: an incomplete gitconfig would
    ## replace git's own "who are you" error with a stranger one.
    environment.etc."nixcage/gitconfig" =
      lib.mkIf (cfg.git.userName != null && cfg.git.userEmail != null)
        {
          text = container.gitConfigText cfg.git;
        };

    ## Rendered only when a role uid range is declared: an ordinary session
    ## never reads it, and a role session refuses to start without it.
    environment.etc."nixcage/factory" = lib.mkIf (cfg.supervisor.roleUidRange != null) {
      text = ''
        ROLE_UID_BASE=${toString cfg.supervisor.roleUidRange.base}
        ROLE_UID_SIZE=${toString cfg.supervisor.roleUidRange.size}
        TASK_MAX_ATTEMPTS=${toString cfg.supervisor.taskAttempts}
        TASK_TIMEOUT_SECONDS=${toString cfg.supervisor.runTimeoutSeconds}
        RUN_CONCURRENCY=${toString cfg.supervisor.concurrency}
      '';
    };

    environment.etc."nixcage/profile".source = container.profile;
    environment.etc."nixcage/secret-env".text = lib.concatStrings (
      lib.mapAttrsToList (var: secret: "${var}=${secret}\n") cfg.secretEnv
    );
    environment.etc."nixcage/config".text = ''
      WORKSPACE_ROOTS=${lib.concatStringsSep ":" cfg.workspaceRoots}
    '';

    ## The container homes and skeletons live where the VM keeps them, so
    ## the container script needs no platform branch.
    systemd.tmpfiles.rules = [
      "d /var/lib/nixcage 0755 root root -"
    ];
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
              { "nixcage/factories/${factoryName}/repository".text = factory.repository + "\n"; }
            ]
            ++ lib.mapAttrsToList (roleName: role: {
              "nixcage/factories/${factoryName}/roles/${roleName}/declared".text = "";
            }) factory.roles
            ++ lib.mapAttrsToList (
              roleName: role:
              lib.mkIf (role.command != null) {
                ## One word per line: a command is argv, never a shell line, so
                ## nothing in it is re-split or expanded by anything.
                "nixcage/factories/${factoryName}/roles/${roleName}/command".text =
                  lib.concatMapStrings (word: word + "\n") role.command;
              }
            ) factory.roles
            ++ lib.mapAttrsToList (
              roleName: role:
              lib.mkIf (role.shell != null) {
                ## Just the name: the toolchain itself is the project's, and
                ## nixcage only carries which of its shells this role enters.
                "nixcage/factories/${factoryName}/roles/${roleName}/shell".text = role.shell + "\n";
              }
            ) factory.roles
                      ++ lib.concatLists (
            lib.mapAttrsToList (
              workflowName: workflow:
              (lib.imap0 (i: stage: {
                "nixcage/factories/${factoryName}/workflows/${workflowName}/stages/${
                  lib.fixedWidthNumber 2 i
                }/role".text = stage.role + "\n";
              }) workflow.stages)
              ++ (lib.imap0 (
                i: stage:
                lib.mkIf stage.fanOut {
                  "nixcage/factories/${factoryName}/workflows/${workflowName}/stages/${
                    lib.fixedWidthNumber 2 i
                  }/fanout".text = "";
                }
              ) workflow.stages)
              ++ (lib.imap0 (
                i: stage:
                lib.mkIf (stage.gate != null) {
                  "nixcage/factories/${factoryName}/workflows/${workflowName}/stages/${
                    lib.fixedWidthNumber 2 i
                  }/gate".text = stage.gate + "\n";
                }
              ) workflow.stages)
              ++ lib.concatLists (
                lib.mapAttrsToList (
                  asker: targets:
                  map (target: {
                    "nixcage/factories/${factoryName}/workflows/${workflowName}/consults/${asker}/${target}".text =
                      "";
                  }) targets
                ) workflow.consults
              )
              ++ [
                {
                  "nixcage/factories/${factoryName}/workflows/${workflowName}/budget-runs".text =
                    toString workflow.budget.runs + "\n";
                  "nixcage/factories/${factoryName}/workflows/${workflowName}/budget-tokens".text =
                    toString workflow.budget.tokens + "\n";
                }
              ]
            ) factory.workflows
          )
          ) cfg.factories
        )
      );

      ## A factory whose roles have no uid range cannot give them identities.
      assertions = lib.mapAttrsToList (name: _: {
        assertion = cfg.supervisor.roleUidRange != null;
        message = "nixcage.factories.${name} needs nixcage.supervisor.roleUidRange";
      }) cfg.factories;
    }
  ];
}
