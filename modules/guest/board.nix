## The board, the record and the forge: Forgejo on the factory's pool
## (ADR-036).
##
## It listens on the bridge, where a cage can reach it and nothing off the
## machine can. Its data lives under the state directory on a dataset asked
## for through the storage primitive and bounded by recordQuota, because a
## record that grows without bound takes every worktree on the pool with it.
##
## Accounts, tokens, labels and the memory issues are cageworks up's to make
## and to make again without changing anything (ADR-036, roadmap 2.3); this
## file only gives them a forge to be made in.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cageworks.machine;
  stateDir = "/var/lib/nixcage";
  plan = builtins.fromJSON config.environment.etc."cageworks/bridge.json".text;
in
{
  options.cageworks.machine.recordQuota = lib.mkOption {
    type = lib.types.int;
    default = 4096;
    description = ''
      Size in MiB the record may reach, as the factory asked and the operator
      allowed (ADR-036). A default rather than a required value, for the
      reason the ledger's bound had one: refusing to boot over an unstated
      number is a worse answer than a modest one.
    '';
  };

  config = {
    services.forgejo = {
      enable = true;
      stateDir = "${stateDir}/forgejo";
      database.type = "sqlite3";
      settings = {
        server = {
          HTTP_ADDR = plan.host;
          HTTP_PORT = cfg.forgejoPort;
          DOMAIN = plan.host;
          ROOT_URL = "http://${plan.forgejo}/";
          ## Nothing on this machine pushes over ssh; the executor is local
          ## and a role holds no repository credential (ADR-036 point 5).
          DISABLE_SSH = true;
        };
        service.DISABLE_REGISTRATION = true;
        security.INSTALL_LOCK = true;
        ## The record is metadata about work and is read by the operator on
        ## the forwarded port; nothing here is federated or mailed.
        federation.ENABLED = false;
        mailer.ENABLED = false;
      };
    };

    ## Where the record lives, asked for through the primitive rather than
    ## with zfs, and before Forgejo opens it. The forge's uid is allocated by
    ## NixOS, so it is resolved when this runs rather than named.
    systemd.services.cageworks-record = {
      description = "The storage this factory's record lives on";
      wantedBy = [ "multi-user.target" ];
      requires = [ "cageworks-storage.service" ];
      after = [ "cageworks-storage.service" ];
      before = [ "forgejo.service" ];
      requiredBy = [ "forgejo.service" ];
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
          ${stateDir}/forgejo "$(id -u forgejo)" ${toString cfg.recordQuota}M >/dev/null
        chown forgejo:forgejo ${stateDir}/forgejo
        chmod 0750 ${stateDir}/forgejo
      '';
    };
  };
}
