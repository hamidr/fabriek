## What the kernel says a role ran (ADR-038 point 3).
##
## A probe on the host sees every process in every cage of every factory,
## attributed by the uid nixcage allocated, because nspawn cages share
## this kernel; a microVM role's processes are seen at its boundary only.
## Three probes and no more, observing only: denying a role an exec is the
## shape of a cage, and a cage is nixcage's (ADR-018).
##
## One reader for the host (ADR-067 point 2): the kernel is one. Each line
## goes to the bus of the factory the cgroup belongs to as one entry on a
## capped stream, written by a user that can write that stream and nothing
## else; the machine program does the writing over every factory's facts,
## naming the factory and the role (modules/probes.sh). Nothing persists
## it: the operator watches it live.
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
    environment.etc."fabriek/probes.bt".text = ''
      /* Filtered here rather than downstream: a predicate compiles into the
       * program, so an event the host does not want never leaves the
       * kernel. uid 0 is the host itself; no role is ever root. The cgroup
       * is the cage (nixcage ADR-012): every process a cage starts is in
       * its scope, whatever uid it takes, and the publisher names the
       * factory and the role from it. */
      tracepoint:sched:sched_process_exec / uid != 0 /
      {
        printf("exec cgroup=%d uid=%d pid=%d comm=%s\n", cgroup, uid, pid, comm);
      }

      tracepoint:sched:sched_process_exit / uid != 0 /
      {
        printf("exit cgroup=%d uid=%d pid=%d comm=%s\n", cgroup, uid, pid, comm);
      }

      kprobe:tcp_connect / uid != 0 /
      {
        printf("connect cgroup=%d uid=%d pid=%d comm=%s\n", cgroup, uid, pid, comm);
      }
    '';

    systemd.services.fabriek-probes = {
      description = "What the kernel says the factories ran, onto each one's bus";
      wantedBy = [ "multi-user.target" ];
      after = map (name: "fabriek-${name}-bus-acl.service") (lib.attrNames cfg.plan);
      wants = map (name: "fabriek-${name}-bus-acl.service") (lib.attrNames cfg.plan);
      environment.FABRIEK_FACTORIES = "/etc/fabriek/factories";
      serviceConfig = {
        Restart = "on-failure";
        RestartSec = 5;
      };
      path = [
        pkgs.coreutils
        pkgs.bpftrace
        pkgs.valkey
        pkgs.fabriek-container
        "/run/current-system/sw"
      ];
      script = ''
        set -u
        bpftrace -q -f text /etc/fabriek/probes.bt | fabriek-container probes-publish
      '';
    };
  };
}
