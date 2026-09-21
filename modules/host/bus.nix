## The bus: Valkey on a factory's bridge, control plane only (ADR-033),
## one per factory (ADR-067).
##
## No persistence, because state that matters is on the board. One ACL
## user per actor, default-deny and then the handful of stream verbs it
## needs; the rules are the machine program's (modules/bus.sh), applied at
## start and on request, from the password files up writes. A user whose
## file is absent is not created, which is what a factory never brought up
## looks like.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fabriek;
  perFactory = f: lib.listToAttrs (lib.concatLists (lib.mapAttrsToList (name: p: f name p) cfg.plan));
in
{
  config = lib.mkIf cfg.enable {
    systemd.services = perFactory (
      name: p: [
        (lib.nameValuePair "fabriek-${name}-bus" {
          description = "The factory ${name}'s bus";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];
          serviceConfig = {
            ## Nothing saved and nothing appended: a restart is an empty
            ## bus, and every actor re-announces itself (ADR-033).
            ExecStart = "${pkgs.valkey}/bin/valkey-server --bind ${p.host} --port ${toString cfg.ports.valkey} --save \"\" --appendonly no --protected-mode no";
            Restart = "on-failure";
            DynamicUser = true;
            Slice = "fabriek-${name}.slice";
          };
        })
        ## The ACL, applied from the password files that exist. Restarted
        ## by prepare after it writes them, so a new role's user appears
        ## without a reboot; before render there is no declaration and the
        ## verb applies nothing.
        (lib.nameValuePair "fabriek-${name}-bus-acl" {
          description = "Who may say what on the factory ${name}'s bus";
          wantedBy = [ "multi-user.target" ];
          requires = [
            "fabriek-${name}-bus.service"
            "fabriek-${name}-state.service"
          ];
          after = [
            "fabriek-${name}-bus.service"
            "fabriek-${name}-state.service"
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            EnvironmentFile = "/etc/fabriek/factories/${name}.env";
            Slice = "fabriek-${name}.slice";
          };
          path = [
            pkgs.coreutils
            pkgs.gnugrep
            pkgs.jq
            pkgs.valkey
            pkgs.fabriek-container
            "/run/current-system/sw"
          ];
          script = "fabriek-container bus-acl";
        })
      ]
    );
  };
}
