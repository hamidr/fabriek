## The bus: Valkey on the bridge, control plane only (ADR-033).
##
## No persistence, because state that matters is on the board. One ACL user
## per actor, default-deny and then the handful of stream verbs it needs; the
## rules are the machine program's (modules/bus.sh), applied here at boot and
## on request, from the password files fabriek up writes (roadmap 2.3). A
## user whose file is absent is not created, which is what a factory that has
## never been brought up looks like.
{
  config,
  pkgs,
  ...
}:
let
  cfg = config.fabriek.machine;
  host = config.environment.variables.FABRIEK_BRIDGE_HOST;
in
{
  config = {
    systemd.services.fabriek-bus = {
      description = "This factory's bus";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        ## Nothing saved and nothing appended: a restart is an empty bus, and
        ## every actor re-announces itself (ADR-033).
        ExecStart = "${pkgs.valkey}/bin/valkey-server --bind ${host} --port ${toString cfg.valkeyPort} --save \"\" --appendonly no --protected-mode no";
        Restart = "on-failure";
        DynamicUser = true;
      };
    };

    ## The ACL, applied from the password files that exist. Restarted by
    ## factory-prepare after it writes them, so a new role's user appears
    ## without a reboot; before prepare there is no declaration and the
    ## verb applies nothing.
    systemd.services.fabriek-bus-acl = {
      description = "Who may say what on this factory's bus";
      wantedBy = [ "multi-user.target" ];
      requires = [
        "fabriek-bus.service"
        "fabriek-storage.service"
      ];
      after = [
        "fabriek-bus.service"
        "fabriek-storage.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
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
    };
  };
}
