## nixcage NixOS module: options plus base configuration for the single
## shared VM. Imported by the user's config flake together with
## microvm.nixosModules.microvm (and optionally sops-nix).
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
        Absolute host directories shared into the VM. Each root is mounted
        at the same absolute path inside the VM, so a project's path is
        identical on both sides. Only flake directories under a root can be
        entered.
      '';
    };

    sshPort = lib.mkOption {
      type = lib.types.port;
      default = 22022;
      description = "Host port forwarded to the VM's SSH daemon.";
    };

    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = ''
        SSH public keys allowed to enter the VM. The host CLI generates a
        keypair at ~/.local/state/nixcage/id_ed25519 on first start and
        prints the public key to paste here.
      '';
    };

    shareProto = lib.mkOption {
      type = lib.types.enum [
        "virtiofs"
        "9p"
      ];
      ## Since ADR-003 this VM only runs on macOS hosts, where virtiofsd
      ## does not exist; 9p is the only working default.
      default = "9p";
      description = "Share protocol for workspace roots: 9p on macOS hosts, virtiofs on Linux hosts.";
    };

    secretEnv = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        ANTHROPIC_API_KEY = "anthropic";
      };
      description = ''
        Environment variable to sops secret name mapping. Each container
        session gets the variable set from /run/secrets/<name>. The host
        environment is never read.
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

    vm = {
      cpus = lib.mkOption {
        type = lib.types.ints.positive;
        default = 4;
        description = "Number of virtual CPUs.";
      };
      mem = lib.mkOption {
        type = lib.types.ints.positive;
        default = 4096;
        description = "VM memory in MiB.";
      };
      diskSize = lib.mkOption {
        type = lib.types.ints.positive;
        default = 20480;
        description = "Size in MiB of each persistent volume (Nix store overlay and container data).";
      };
    };
  };

  config = lib.mkMerge [
    {
    assertions = [
      {
        assertion = cfg.authorizedKeys != [ ];
        message = ''
          nixcage.authorizedKeys is empty: nobody could SSH into the VM and
          'nixcage enter' would hang until timeout. Paste the public key the
          CLI prints on first run (~/.local/state/nixcage/id_ed25519.pub).
        '';
      }
    ];

    ## The VM owns its store: the closure ships as a read-only image and
    ## builds land in a persistent writable overlay. The host store is
    ## never shared into the guest.
    microvm = {
      hypervisor = "qemu";
      vcpu = cfg.vm.cpus;
      mem = cfg.vm.mem;
      writableStoreOverlay = "/nix/.rw-store";

      volumes = [
        {
          image = "nixcage-store.img";
          mountPoint = "/nix/.rw-store";
          size = cfg.vm.diskSize;
        }
        {
          image = "nixcage-data.img";
          mountPoint = "/var/lib/nixcage";
          size = cfg.vm.diskSize;
        }
      ];

      shares = lib.imap0 (i: root: {
        tag = "ws${toString i}";
        source = root;
        mountPoint = root;
        proto = cfg.shareProto;
      }) cfg.workspaceRoots;

      interfaces = [
        {
          type = "user";
          id = "nixcage0";
          mac = "02:00:00:00:00:01";
        }
      ];

      forwardPorts = [
        {
          from = "host";
          host.port = cfg.sshPort;
          guest.port = 22;
        }
      ];
    };

    environment.systemPackages = [
      container.script
      pkgs.git
      pkgs.age
    ];

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
      '';
    };

    environment.etc."nixcage/profile".source = container.profile;
    environment.etc."nixcage/secret-env".text = lib.concatStrings (
      lib.mapAttrsToList (var: secret: "${var}=${secret}\n") cfg.secretEnv
    );

    ## Generate the age identity on the data volume at first boot so the
    ## user can read the public key (nixcage status) before declaring any
    ## sops secret. sops-nix's own generateKey only runs once secrets
    ## exist, which is too late for that bootstrap.
    systemd.services.nixcage-age-key = {
      description = "Generate the nixcage age identity";
      wantedBy = [ "multi-user.target" ];
      ## Without the mount ordering the key lands on the ephemeral rootfs
      ## and is shadowed once the volume mounts (observed as an empty
      ## age.key). -s, not -f: an empty file from such a race must not
      ## satisfy the guard.
      after = [ "var-lib-nixcage.mount" ];
      requires = [ "var-lib-nixcage.mount" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        if [ ! -s /var/lib/nixcage/age.key ]; then
          umask 077
          rm -f /var/lib/nixcage/age.key
          ${pkgs.age}/bin/age-keygen -o /var/lib/nixcage/age.key
        fi
      '';
    };

    ## sshd generates its persistent host key in preStart; force it after
    ## the data volume mount or the first boot serves a throwaway tmpfs key
    ## and every later boot fails host key verification.
    systemd.services.sshd = {
      after = [ "var-lib-nixcage.mount" ];
      requires = [ "var-lib-nixcage.mount" ];
    };

    nix = {
      settings = {
        experimental-features = [
          "nix-command"
          "flakes"
        ];

        ## Every project's devShell is a separate closure in the same overlay,
        ## and they overlap heavily; hardlinking the duplicates is most of what
        ## keeps a many-project VM from filling one.
        auto-optimise-store = lib.mkDefault true;
      };

      ## The store overlay is a fixed-size volume that only grows: containers
      ## build into it for the life of the VM and nothing else prunes it.
      ## Every value is mkDefault, so a config flake can lengthen the window,
      ## change the schedule, or turn collection off entirely.
      ##
      ## 'nix develop' keeps only a temporary root, so a collection between
      ## sessions drops the devShell closures and the next enter refetches
      ## them. That is the cost of not filling the volume.
      gc = {
        automatic = lib.mkDefault true;
        dates = lib.mkDefault "weekly";
        options = lib.mkDefault "--delete-older-than 30d";
      };
    };

    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "no";
      };
      ## On the data volume: the rootfs is ephemeral, and a stable host key
      ## lets the CLI verify every boot after the first instead of blindly
      ## re-accepting a fresh key each time.
      hostKeys = [
        {
          path = "/var/lib/nixcage/ssh_host_ed25519_key";
          type = "ed25519";
        }
      ];
    };

    users.users.nixcage = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      shell = pkgs.bash;
      openssh.authorizedKeys.keys = cfg.authorizedKeys;
    };

    security.sudo.wheelNeedsPassword = false;

    networking.hostName = "nixcage";

    system.stateVersion = "24.11";
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
