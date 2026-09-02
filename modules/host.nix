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

    supervisor = lib.mkOption {
      type = lib.types.submodule {
        options = {
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

  config = {
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
  };
}
