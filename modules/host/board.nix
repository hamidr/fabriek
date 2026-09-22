## The board, the record and the forge: one Forgejo for the host, on every
## factory's bridge and on one dataset of the host's (ADR-036, ADR-068).
##
## Forgejo's NixOS module is one instance per host and so is this unit, a
## unit of ours because its app.ini, its secrets and its repository root
## are fabriek's to place: the secrets are made in the dataset on first
## start and read back through environment-to-ini, the way the module does
## it.
##
## What keeps two factories apart is not the instance any more but the
## accounts in it (ADR-068 point 2): a factory's repository is owned by
## <factory>-operator, an ordinary account, and a role is a read
## collaborator on that repository and on nothing else. Accounts, tokens,
## labels and the memory issues are prepare's to make and to make again
## without changing anything (ADR-036); this file only gives them a forge
## to be made in.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fabriek;
  format = pkgs.formats.ini { };
  exe = lib.getExe pkgs.forgejo;
  ## Under nixcage's state directory, because the pool is mounted there and
  ## nowhere else, and beside the factories rather than among them: a
  ## factory called forge would otherwise name this dataset.
  workDir = "/var/lib/nixcage/fabriek-forge";
  customDir = "${workDir}/custom";
  ## The forge answers on every factory's bridge; the host's firewall opens
  ## its port on those bridges and on loopback alone (bridge.nix), and the
  ## forward chain drops anything off a bridge (proxy.nix), so binding
  ## every address is not reaching any further than one. ROOT_URL is
  ## loopback: nothing in factory/src reads a URL the forge builds, and an
  ## operator who opens the board from a bridge sees links to loopback.
  settings = {
    DEFAULT = {
      RUN_MODE = "prod";
      RUN_USER = "forgejo";
      WORK_PATH = workDir;
    };
    server = {
      HTTP_ADDR = "0.0.0.0";
      HTTP_PORT = cfg.ports.forgejo;
      DOMAIN = "127.0.0.1";
      ROOT_URL = "http://127.0.0.1:${toString cfg.ports.forgejo}/";
      ## Nothing on the host pushes over ssh; the executor is local and a
      ## role holds no repository credential (ADR-036 point 5).
      DISABLE_SSH = true;
    };
    database = {
      DB_TYPE = "sqlite3";
      PATH = "${workDir}/data/forgejo.db";
    };
    repository.ROOT = "${workDir}/repositories";
    session.COOKIE_NAME = "session";
    service.DISABLE_REGISTRATION = true;
    security.INSTALL_LOCK = true;
    ## The record is metadata about work and is read by the operator on
    ## the bridge; nothing here is federated or mailed.
    federation.ENABLED = false;
    mailer.ENABLED = false;
  };
in
{
  options.services.fabriek = {
    recordQuota = lib.mkOption {
      type = lib.types.int;
      default = 4096;
      description = ''
        Size in MiB the forge's dataset may reach, every factory's record
        in it (ADR-068 point 8). The bound is the host's: a factory does
        not ask for one and nothing clamps.
      '';
    };
    ## Read-only: what the board answers as, so a scenario reads it
    ## without parsing an ini file.
    board = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      default = {
        inherit settings;
        work = workDir;
      };
      description = "The Forgejo settings the host's board runs with, and where it works.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.forgejo = {
      isSystemUser = true;
      group = "forgejo";
      description = "Runs the host's board";
    };
    users.groups.forgejo = { };

    ## The forge's CLI, as the machine program runs it: as the forge's own
    ## user and against the one work directory, which is how an account is
    ## made when registration is off and how a token is minted without a
    ## login. Every call takes the host-wide lock (ADR-068 point 5), since
    ## the CLI opens the sqlite database beside the running server and two
    ## factories prepare under locks of their own.
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "forgejo" ''
        exec ${pkgs.util-linux}/bin/runuser -u forgejo -- \
          env FORGEJO_WORK_DIR=${workDir} GITEA_WORK_DIR=${workDir} \
          ${exe} --config ${customDir}/conf/app.ini "$@"
      '')
      pkgs.curl
    ];

    systemd.services = {
      ## Where every factory's record lives, asked for through the
      ## primitive and before Forgejo opens it. The forge's uid is
      ## allocated by NixOS, so it is resolved when this runs rather than
      ## named.
      fabriek-forge-storage = {
        description = "The storage the host's board lives on";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        path = [
          pkgs.coreutils
          "/run/current-system/sw"
        ];
        script = ''
          set -eu
          nixcage-container storage ensure \
            ${workDir} "$(id -u forgejo)" ${toString cfg.recordQuota}M >/dev/null
          chown forgejo:forgejo ${workDir}
          chmod 0750 ${workDir}
          ## The forge's tmpfiles rules ran at boot, before this dataset
          ## was mounted over the directory they made; run again now that
          ## it is here.
          systemd-tmpfiles --create --prefix=${workDir}
        '';
      };
      fabriek-forge = {
        description = "The host's board";
        wantedBy = [ "multi-user.target" ];
        requires = [ "fabriek-forge-storage.service" ];
        after = [
          "fabriek-forge-storage.service"
          "network.target"
        ];
        environment = {
          USER = "forgejo";
          HOME = workDir;
          FORGEJO_WORK_DIR = workDir;
          FORGEJO_CUSTOM = customDir;
          ## Read back into app.ini by environment-to-ini, from the files
          ## preStart made; the ini itself carries no secret.
          FORGEJO__security__SECRET_KEY__FILE = "${customDir}/conf/secret_key";
          FORGEJO__security__INTERNAL_TOKEN__FILE = "${customDir}/conf/internal_token";
          FORGEJO__oauth2__JWT_SECRET__FILE = "${customDir}/conf/oauth2_jwt_secret";
        };
        preStart = ''
          set -eu
          umask 027
          conf=${customDir}/conf
          mkdir -p "$conf"
          [ -s "$conf/secret_key" ] || ${exe} generate secret SECRET_KEY >"$conf/secret_key"
          [ -s "$conf/internal_token" ] || ${exe} generate secret INTERNAL_TOKEN >"$conf/internal_token"
          [ -s "$conf/oauth2_jwt_secret" ] || ${exe} generate secret JWT_SECRET >"$conf/oauth2_jwt_secret"
          cp -f ${format.generate "app.ini" settings} "$conf/app.ini"
          chmod u+w "$conf/app.ini"
          ${lib.getExe' pkgs.forgejo "environment-to-ini"} --config "$conf/app.ini"
          chmod u-w "$conf/app.ini"
          ${exe} migrate
        '';
        serviceConfig = {
          Type = "notify";
          User = "forgejo";
          Group = "forgejo";
          WorkingDirectory = workDir;
          ExecStart = "${exe} web --pid /run/fabriek-forge/forgejo.pid";
          Restart = "always";
          RuntimeDirectory = "fabriek-forge";
        };
      };
    };
  };
}
