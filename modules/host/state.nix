## Where a factory's state lives on the host (ADR-067 point 3): a dataset
## under nixcage's pool per factory, asked for through the storage
## primitive rather than with zfs, so the pool stays nixcage's (ADR-018).
## Everything of the factory that is not the rendered directory is under
## it: the record, the keys, the bus and forge secrets, the worktrees. One
## slice per factory holds every unit of it.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fabriek;
in
{
  config = lib.mkIf cfg.enable {
    systemd.slices = lib.mapAttrs' (
      name: _: lib.nameValuePair "fabriek-${name}" { description = "The factory ${name}"; }
    ) cfg.plan;

    systemd.services = lib.mapAttrs' (
      name: p:
      lib.nameValuePair "fabriek-${name}-state" {
        description = "The storage the factory ${name}'s state lives on";
        wantedBy = [ "multi-user.target" ];
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
          nixcage-container storage ensure ${p.state} 0 >/dev/null
          chmod 0755 ${p.state}
        '';
      }
    ) cfg.plan;
  };
}
