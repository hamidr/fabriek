## What the kernel says a role ran (ADR-038 point 3).
##
## A probe in the machine's init namespace sees every process in every cage,
## attributed by the uid nixcage allocated, because cages share this kernel.
## Three probes and no more, observing only: denying a role an exec is the
## shape of a cage, and a cage is nixcage's (ADR-018).
##
## Each line goes to the bus as one entry on a capped stream, written by a
## user that can write that stream and nothing else, so the third source stays
## independent of every role; the machine program does the writing, naming the
## role each uid belongs to (modules/probes.sh). Nothing persists it: the
## operator watches it live, and a machine with no bus password yet logs to
## its own journal.
{
  config,
  pkgs,
  ...
}:
let
  cfg = config.cageworks.machine;
in
{
  config = {
    environment.etc."cageworks/probes.bt".text = ''
      /* Filtered here rather than downstream: a predicate compiles into the
       * program, so an event the machine does not want never leaves the
       * kernel. uid 0 is the machine itself; no role is ever root. */
      tracepoint:sched:sched_process_exec / uid != 0 /
      {
        printf("exec uid=%d pid=%d comm=%s\n", uid, pid, comm);
      }

      tracepoint:sched:sched_process_exit / uid != 0 /
      {
        printf("exit uid=%d pid=%d comm=%s\n", uid, pid, comm);
      }

      kprobe:tcp_connect / uid != 0 /
      {
        printf("connect uid=%d pid=%d comm=%s\n", uid, pid, comm);
      }
    '';

    systemd.services.cageworks-probes = {
      description = "What the kernel says this factory ran, onto the bus";
      wantedBy = [ "multi-user.target" ];
      after = [ "cageworks-bus-acl.service" ];
      wants = [ "cageworks-bus-acl.service" ];
      serviceConfig = {
        Restart = "on-failure";
        RestartSec = 5;
      };
      path = [
        pkgs.coreutils
        pkgs.bpftrace
        pkgs.valkey
        pkgs.cageworks-container
        "/run/current-system/sw"
      ];
      script = ''
        set -u
        bpftrace -q -f text /etc/cageworks/probes.bt | cageworks-container probes-publish ${cfg.factory}
      '';
    };
  };
}
