## The bus: Valkey on the bridge, control plane only (ADR-033).
##
## No persistence, because state that matters is on the board. One ACL user
## per actor, default-deny and then the handful of stream verbs it needs; the
## rules are the guest program's (modules/bus.sh), applied here at boot and
## on request, from the password files cageworks up writes (roadmap 2.3). A
## user whose file is absent is not created, which is what a factory that has
## never been brought up looks like.
{
  config,
  pkgs,
  ...
}:
let
  cfg = config.cageworks.machine;
  plan = builtins.fromJSON config.environment.etc."cageworks/bridge.json".text;
in
{
  config = {
    systemd.services.cageworks-bus = {
      description = "This factory's bus";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        ## Nothing saved and nothing appended: a restart is an empty bus, and
        ## every actor re-announces itself (ADR-033).
        ExecStart = "${pkgs.valkey}/bin/valkey-server --bind ${plan.host} --port ${toString cfg.valkeyPort} --save \"\" --appendonly no --protected-mode no";
        Restart = "on-failure";
        DynamicUser = true;
      };
    };

    ## The ACL, applied from the password files that exist. Restarted by
    ## cageworks up after it writes them, so a new role's user appears
    ## without a reboot.
    systemd.services.cageworks-bus-acl = {
      description = "Who may say what on this factory's bus";
      wantedBy = [ "multi-user.target" ];
      requires = [
        "cageworks-bus.service"
        "cageworks-storage.service"
      ];
      after = [
        "cageworks-bus.service"
        "cageworks-storage.service"
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
        pkgs.cageworks-container
        "/run/current-system/sw"
      ];
      script = "cageworks-container bus-acl ${cfg.factory}";
    };
  };
}
