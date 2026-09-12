## The bus: Valkey on the bridge, control plane only (ADR-033).
##
## No persistence, because state that matters is on the board. One ACL user
## per actor, default-deny and then the handful of stream verbs it needs, with
## read and write patterns kept apart: a role reads its mailbox and every
## findings stream, and writes its own findings, its own events and its own
## control stream; the decider reads everything and writes only commands; the
## probes write one stream; the executor holds the bus. The default user is
## off, so a connection that names nobody can do nothing.
##
## Passwords are files under the state directory that cageworks up writes
## (roadmap 2.3) and this machine applies at boot and on request. A user whose
## file is absent is not created, which is what a factory that has never been
## brought up looks like.
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
  roles = lib.attrNames (cfg.declaration.roles or { });
  streamVerbs = "+xadd +xread +xrange +xrevrange +xlen +xinfo +ping";
  ## What each actor may touch, as ACL rules. %R~ is read-only on a key
  ## pattern and %W~ write-only, which is the whole point: attribution on a
  ## findings stream is the ACL's rather than the message's (ADR-033 point 3).
  rulesOf = {
    decider = "resetkeys resetchannels nocommands ${streamVerbs} %R~* %W~commands";
    executor = "resetkeys resetchannels allcommands allkeys allchannels";
    probes = "resetkeys resetchannels nocommands +xadd +ping %W~probes";
  }
  // lib.genAttrs roles (
    r:
    "resetkeys resetchannels nocommands ${streamVerbs} "
    + "%R~mailbox:${r} %W~control:${r} %W~findings:${r} %R~findings:* %W~events:${r}"
  );
  cli = "${pkgs.valkey}/bin/valkey-cli -h ${plan.host} -p ${toString cfg.valkeyPort}";
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
      path = [ pkgs.coreutils ];
      script = ''
        set -eu
        for _ in $(seq 1 30); do
          ${cli} ping >/dev/null 2>&1 && break
          sleep 1
        done
        ${cli} ACL SETUSER default off >/dev/null
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (user: rules: ''
            if [ -s ${stateDir}/bus/${user} ]; then
              ${cli} ACL SETUSER ${user} on ">$(cat ${stateDir}/bus/${user})" ${rules} >/dev/null
            fi
          '') rulesOf
        )}
      '';
    };
  };
}
