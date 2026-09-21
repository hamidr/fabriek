## The board, the record and the forge: Forgejo per factory, on the
## factory's bridge and in the record's dataset (ADR-036, ADR-067).
##
## Forgejo's NixOS module is one instance per host, so the board is a unit
## of ours: its app.ini generated from the settings below, its secrets made
## in the record's dataset on first start and read back through
## environment-to-ini, the way the module does it. One forgejo user serves
## every instance; what keeps two boards apart is the dataset each works
## in, the address each listens on and the accounts each holds.
##
## Accounts, tokens, labels and the memory issues are prepare's to make and
## to make again without changing anything (ADR-036); this file only gives
## them a forge to be made in.
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
  perFactory = f: lib.listToAttrs (lib.concatLists (lib.mapAttrsToList (name: p: f name p) cfg.plan));
  workDir = p: "${p.state}/forgejo";
  customDir = p: "${workDir p}/custom";
  ## What one instance answers as, at its bridge address.
  settings = name: p: {
    DEFAULT = {
      RUN_MODE = "prod";
      RUN_USER = "forgejo";
      WORK_PATH = workDir p;
    };
    server = {
      HTTP_ADDR = p.host;
      HTTP_PORT = cfg.ports.forgejo;
      DOMAIN = p.host;
      ROOT_URL = "http://${p.host}:${toString cfg.ports.forgejo}/";
      ## Nothing on the host pushes over ssh; the executor is local and a
      ## role holds no repository credential (ADR-036 point 5).
      DISABLE_SSH = true;
    };
    database = {
      DB_TYPE = "sqlite3";
      PATH = "${workDir p}/data/forgejo.db";
    };
    repository.ROOT = "${workDir p}/repositories";
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
        Size in MiB a record may reach before prepare has applied what the
        factory asked and the operator allowed (ADR-036): prepare asks the
        storage primitive again with the clamped number.
      '';
    };
    ## Read-only: what each board answers as, so a scenario reads it
    ## without parsing an ini file.
    boards = lib.mkOption {
      type = lib.types.attrsOf lib.types.attrs;
      readOnly = true;
      default = lib.mapAttrs (name: p: { settings = settings name p; }) cfg.plan;
      description = "Per factory, the Forgejo settings its board runs with.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.forgejo = {
      isSystemUser = true;
      group = "forgejo";
      description = "Runs every factory's board";
    };
    users.groups.forgejo = { };

    ## The forge's CLI, as the machine program runs it: as the forge's own
    ## user and against the configuration of the factory in the caller's
    ## environment, which is how an account is made when registration is
    ## off and how a token is minted without a login.
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "forgejo" ''
        [ -n "''${FABRIEK_STATE:-}" ] || { echo "forgejo: FABRIEK_STATE names the factory's state" >&2; exit 1; }
        exec ${pkgs.util-linux}/bin/runuser -u forgejo -- \
          env FORGEJO_WORK_DIR="$FABRIEK_STATE/forgejo" GITEA_WORK_DIR="$FABRIEK_STATE/forgejo" \
          ${exe} --config "$FABRIEK_STATE/forgejo/custom/conf/app.ini" "$@"
      '')
      pkgs.curl
    ];

    systemd.services = perFactory (
      name: p: [
        ## Where the record lives, asked for through the primitive and
        ## before Forgejo opens it. The forge's uid is allocated by NixOS,
        ## so it is resolved when this runs rather than named.
        (lib.nameValuePair "fabriek-${name}-record" {
          description = "The storage the factory ${name}'s record lives on";
          wantedBy = [ "multi-user.target" ];
          requires = [ "fabriek-${name}-state.service" ];
          after = [ "fabriek-${name}-state.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            Slice = "fabriek-${name}.slice";
          };
          path = [
            pkgs.coreutils
            "/run/current-system/sw"
          ];
          script = ''
            set -eu
            nixcage-container storage ensure \
              ${workDir p} "$(id -u forgejo)" ${toString cfg.recordQuota}M >/dev/null
            chown forgejo:forgejo ${workDir p}
            chmod 0750 ${workDir p}
            ## The forge's tmpfiles rules ran at boot, before this dataset
            ## was mounted over the directory they made; run again now that
            ## it is here.
            systemd-tmpfiles --create --prefix=${workDir p}
          '';
        })
        (lib.nameValuePair "fabriek-${name}-board" {
          description = "The factory ${name}'s board";
          wantedBy = [ "multi-user.target" ];
          requires = [ "fabriek-${name}-record.service" ];
          after = [
            "fabriek-${name}-record.service"
            "network.target"
          ];
          environment = {
            USER = "forgejo";
            HOME = workDir p;
            FORGEJO_WORK_DIR = workDir p;
            FORGEJO_CUSTOM = customDir p;
            ## Read back into app.ini by environment-to-ini, from the files
            ## preStart made; the ini itself carries no secret.
            FORGEJO__security__SECRET_KEY__FILE = "${customDir p}/conf/secret_key";
            FORGEJO__security__INTERNAL_TOKEN__FILE = "${customDir p}/conf/internal_token";
            FORGEJO__oauth2__JWT_SECRET__FILE = "${customDir p}/conf/oauth2_jwt_secret";
          };
          preStart = ''
            set -eu
            umask 027
            conf=${customDir p}/conf
            mkdir -p "$conf"
            [ -s "$conf/secret_key" ] || ${exe} generate secret SECRET_KEY >"$conf/secret_key"
            [ -s "$conf/internal_token" ] || ${exe} generate secret INTERNAL_TOKEN >"$conf/internal_token"
            [ -s "$conf/oauth2_jwt_secret" ] || ${exe} generate secret JWT_SECRET >"$conf/oauth2_jwt_secret"
            cp -f ${format.generate "app.ini" (settings name p)} "$conf/app.ini"
            chmod u+w "$conf/app.ini"
            ${lib.getExe' pkgs.forgejo "environment-to-ini"} --config "$conf/app.ini"
            chmod u-w "$conf/app.ini"
            ${exe} migrate
          '';
          serviceConfig = {
            Type = "notify";
            User = "forgejo";
            Group = "forgejo";
            WorkingDirectory = workDir p;
            ExecStart = "${exe} web --pid /run/fabriek-${name}-board/forgejo.pid";
            Restart = "always";
            RuntimeDirectory = "fabriek-${name}-board";
            Slice = "fabriek-${name}.slice";
          };
        })
      ]
    );
  };
}
