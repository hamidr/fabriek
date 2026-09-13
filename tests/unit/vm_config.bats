#!/usr/bin/env bats
# The machine one factory runs in (ADR-019).
#
# One evaluation, several assertions. Evaluating a NixOS configuration is the
# only way to test a NixOS module, and it is slow enough that asking it eight
# questions at once is worth more than eight tests that each ask one.

load ../test_helper/common

setup() {
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

## Every fact this file asserts, from one evaluation, as tab separated fields.
machine_facts() {
	local factory="${1:-acme}"
	nix eval --raw --impure --expr '
    let
      flake = builtins.getFlake (toString '"$CAGEWORKS_ROOT"');
      m = flake.lib.machine {
        system = "aarch64-linux";
        factory = "'"$factory"'";
        sshPort = 22100;
        authorizedKey = "ssh-ed25519 AAAAtest cageworks-'"$factory"'";
      };
      c = m.config;
      pool = builtins.elemAt (builtins.filter (v: v.mountPoint == null) c.microvm.volumes) 0;
    in builtins.concatStringsSep "\t" [
      c.networking.hostName
      c.networking.hostId
      c.nixcage.storage.dataset
      pool.serial
      (toString (builtins.length c.microvm.volumes))
      (toString (builtins.head c.microvm.forwardPorts).host.port)
      (builtins.head c.users.users.root.openssh.authorizedKeys.keys)
      (if c.boot.zfs.forceImportRoot then "forces" else "refuses")
      (if c.services.openssh.settings.PasswordAuthentication then "passwords" else "keys-only")
      (builtins.head c.services.openssh.hostKeys).path
    ]' 2>/dev/null
}

field() {
	printf '%s' "$1" | cut -f"$2"
}

@test "a factory's machine is that factory's, in every name that matters" {
	local facts
	facts="$(machine_facts acme)"
	[ -n "$facts" ]

	# Named after the factory, so two machines are never confused for one.
	[ "$(field "$facts" 1)" = "cageworks-acme" ]
	# The pool carries the factory's name too, so a disk attached to the wrong
	# machine refuses to import rather than being adopted.
	[ "$(field "$facts" 3)" = "cageworks-acme/state" ]
	# Found by serial, because a drive letter moves when the volume list does
	# and the pool would then be created on top of the store.
	[ "$(field "$facts" 4)" = "cageworks-pool" ]
	# The store and the pool, and nothing of the host's shared in.
	[ "$(field "$facts" 5)" = "2" ]
	# The port cageworks was told to reach it on.
	[ "$(field "$facts" 6)" = "22100" ]
}

# ADR-019 point 4: cageworks owns the way in because it owns the VM, and it is
# one key per factory with nothing else accepted.
@test "one key reaches a machine, and a password reaches none" {
	local facts
	facts="$(machine_facts acme)"
	[ "$(field "$facts" 7)" = "ssh-ed25519 AAAAtest cageworks-acme" ]
	[ "$(field "$facts" 9)" = "keys-only" ]
}

# A machine that generates host keys every boot is a different machine every
# boot, and cageworks pins what it connected to. Found by stopping and starting
# one ten times, which failed on the second.
@test "a machine keeps its identity across a stop, because its keys persist" {
	local facts
	facts="$(machine_facts acme)"
	[ "$(field "$facts" 10)" = "/var/lib/nixcage/ssh/ssh_host_ed25519_key" ]
}

# ADR-017 exists because worktrees came back empty. Forcing an import is how a
# pool that should have been looked at is adopted instead.
@test "a pool that will not import cleanly is a fault, not a device to adopt" {
	local facts
	facts="$(machine_facts acme)"
	[ "$(field "$facts" 8)" = "refuses" ]
}

@test "two factories are not the same machine, down to the host identity" {
	local acme widgets
	acme="$(machine_facts acme)"
	widgets="$(machine_facts widgets)"
	[ "$(field "$acme" 1)" != "$(field "$widgets" 1)" ]
	[ "$(field "$acme" 2)" != "$(field "$widgets" 2)" ]
	[ "$(field "$acme" 3)" != "$(field "$widgets" 3)" ]
}

# A machine that rebuilds under a new identity is one that cannot import the
# pool it left behind.
@test "the host identity follows the factory's name rather than the build" {
	local once twice
	once="$(machine_facts acme)"
	twice="$(machine_facts acme)"
	[ "$(field "$once" 2)" = "$(field "$twice" 2)" ]
	[ -n "$(field "$once" 2)" ]
}

# ADR-025: a cage holds no credential and no route. The firewall is where the
# second half of that is true, and it filters on the uid a session's processes
# carry rather than on a host, because a packet filter cannot resolve a name
# and the allowlist is names.

## The machine's egress ruleset and the facts about it, from one evaluation.
egress_ruleset() {
	nix eval --raw --impure --expr '
    let
      flake = builtins.getFlake (toString '"$CAGEWORKS_ROOT"');
      m = flake.lib.machine {
        system = "aarch64-linux";
        factory = "acme";
        sshPort = 22100;
        authorizedKey = "ssh-ed25519 AAAAtest cageworks-acme";
        egress = [ "api.anthropic.com" ];
      };
    in m.config.networking.nftables.tables.cageworks-egress.content'
}

@test "a machine drops egress by default, so a uid nobody allowed reaches nothing" {
	run egress_ruleset
	assert_success
	assert_output --partial "hook output"
	assert_output --partial "policy drop"
}

# The rule names a number and not a name. nftables resolves a user name when
# the ruleset is parsed, and NixOS parses it once at build time in a sandbox
# where the user does not exist, so a name here fails the build.
@test "the proxy is the one uid that may leave the machine on a factory's behalf" {
	run egress_ruleset
	assert_success
	assert_output --partial "meta skuid 500 accept"
	refute_output --partial 'skuid "cageworks-egress"'
}

@test "a role reaches the proxy, which is on the machine, so loopback stays open" {
	run egress_ruleset
	assert_success
	assert_output --partial "lo"
}

@test "no rule names a role, because a role is denied by there being no rule for it" {
	run egress_ruleset
	assert_success
	refute_output --partial "nixbld"
}

@test "the machine has a user for the proxy to be, separate from root and from every role" {
	run nix eval --raw --impure --expr '
    let
      flake = builtins.getFlake (toString '"$CAGEWORKS_ROOT"');
      m = flake.lib.machine {
        system = "aarch64-linux";
        factory = "acme";
        sshPort = 22100;
        authorizedKey = "ssh-ed25519 AAAAtest cageworks-acme";
        egress = [ "api.anthropic.com" ];
      };
      u = m.config.users.users.cageworks-egress;
    in "${u.group}:${toString u.isSystemUser}"'
	assert_success
	assert_output "cageworks-egress:1"
}

@test "what a factory may reach is carried onto its machine as declared" {
	run nix eval --json --impure --expr '
    let
      flake = builtins.getFlake (toString '"$CAGEWORKS_ROOT"');
      m = flake.lib.machine {
        system = "aarch64-linux";
        factory = "acme";
        sshPort = 22100;
        authorizedKey = "ssh-ed25519 AAAAtest cageworks-acme";
        egress = [ "api.anthropic.com" "api.openai.com" ];
      };
    in m.config.cageworks.machine.egress'
	assert_success
	assert_output '["api.anthropic.com","api.openai.com"]'
}

@test "a factory allowed nothing gets a machine that reaches nothing, not one that reaches everything" {
	run nix eval --json --impure --expr '
    let
      flake = builtins.getFlake (toString '"$CAGEWORKS_ROOT"');
      m = flake.lib.machine {
        system = "aarch64-linux";
        factory = "acme";
        sshPort = 22100;
        authorizedKey = "ssh-ed25519 AAAAtest cageworks-acme";
      };
    in m.config.cageworks.machine.egress'
	assert_success
	assert_output '[]'
}

## The proxy's configuration, from one evaluation.
egress_proxy_conf() {
	nix eval --raw --impure --expr '
    let
      flake = builtins.getFlake (toString '"$CAGEWORKS_ROOT"');
      m = flake.lib.machine {
        system = "aarch64-linux";
        factory = "acme";
        sshPort = 22100;
        authorizedKey = "ssh-ed25519 AAAAtest cageworks-acme";
        egress = [ "api.anthropic.com" "example.invalid" ];
        egressHeaders = { "api.anthropic.com" = "x-api-key"; };
      };
    in m.config.services.nginx.virtualHosts."cageworks-egress".extraConfig
      + (builtins.head m.config.services.nginx.virtualHosts."cageworks-egress".listen).addr'
}

@test "each endpoint the factory may reach is a place on the proxy" {
	run egress_proxy_conf
	assert_success
	assert_output --partial "api.anthropic.com"
	assert_output --partial "example.invalid"
}

@test "an endpoint nobody holds a credential for is still reachable, unauthenticated" {
	run egress_proxy_conf
	assert_success
	# example.invalid has no credential and is a location all the same: not
	# every host wants authenticating to.
	assert_output --partial "example.invalid"
}

@test "the credential is included from a file, never written into the configuration" {
	run egress_proxy_conf
	assert_success
	assert_output --partial "include"
	assert_output --partial "/run/cageworks-egress"
}

@test "the proxy is the uid the firewall lets out, and not root" {
	run nix eval --raw --impure --expr '
    let
      flake = builtins.getFlake (toString '"$CAGEWORKS_ROOT"');
      m = flake.lib.machine {
        system = "aarch64-linux";
        factory = "acme";
        sshPort = 22100;
        authorizedKey = "ssh-ed25519 AAAAtest cageworks-acme";
        egress = [ "api.anthropic.com" ];
      };
    in m.config.services.nginx.user'
	assert_success
	assert_output "cageworks-egress"
}

@test "a factory allowed nothing runs no proxy, because there is nothing for it to reach" {
	run nix eval --raw --impure --expr '
    let
      flake = builtins.getFlake (toString '"$CAGEWORKS_ROOT"');
      m = flake.lib.machine {
        system = "aarch64-linux";
        factory = "acme";
        sshPort = 22100;
        authorizedKey = "ssh-ed25519 AAAAtest cageworks-acme";
      };
    in if m.config.services.nginx.enable then "runs" else "does not run"'
	assert_success
	assert_output "does not run"
}

## The names of the commands a machine puts on its own PATH.
machine_commands() {
	local factory="${1:-acme}" egress="${2:-[ \"api.anthropic.com\" ]}"
	nix eval --raw --impure --expr '
    let
      flake = builtins.getFlake (toString '"$CAGEWORKS_ROOT"');
      m = flake.lib.machine {
        system = "aarch64-linux";
        factory = "'"$factory"'";
        sshPort = 22100;
        authorizedKey = "ssh-ed25519 AAAAtest cageworks-'"$factory"'";
        egress = '"$egress"';
      };
    in builtins.concatStringsSep "\n"
      (map (p: p.name or "") m.config.environment.systemPackages)
  ' 2>/dev/null
}

# ADR-018. The operator names a host and pipes a secret; where it lands is the
# machine's business. Without this command the CLI would be calling something
# that is not there, which is the half of the contract a test has to hold.
@test "a machine that may reach somewhere knows how to be handed the credential" {
	run machine_commands acme
	assert_success
	assert_line "cageworks-egress-credential"
}

@test "a machine that may reach nowhere is handed nothing to hold" {
	run machine_commands acme '[ ]'
	assert_success
	refute_line "cageworks-egress-credential"
}

# ADR-027 point 8. Unbounded, the ledger fills the pool and takes every
# worktree with it, which is why the quota is not optional here.

# A sibling of worktrees/ under the state directory, so no role's name reaches
# it and no role's quota is what bounds it.

# microvm.nix gives this machine a tmpfs root, so a ledger that is not put
# somewhere on purpose ends at the next stop.

# The namespace listens at sockets.target and the pool is imported at
# multi-user, so ordering it after the storage is a cycle systemd breaks by
# dropping sockets.target, and the factory boots with no journal at all. It is
# restarted onto the directory instead, which is why this asserts a restart and
# not an ordering.

# nixcage's host module puts the primitive on the machine's own profile, and a
# unit with an explicit path gets only that path.

## What the proxy is configured to write about a request, and where.
proxy_log() {
	local factory="${1:-acme}"
	nix eval --raw --impure --expr '
    let
      flake = builtins.getFlake (toString '"$CAGEWORKS_ROOT"');
      m = flake.lib.machine {
        system = "aarch64-linux";
        factory = "'"$factory"'";
        sshPort = 22100;
        authorizedKey = "ssh-ed25519 AAAAtest cageworks-'"$factory"'";
        egress = [ "api.anthropic.com" ];
      };
      c = m.config;
    in c.services.nginx.commonHttpConfig
       + c.services.nginx.virtualHosts."cageworks-egress".extraConfig
  ' 2>/dev/null
}

# ADR-027 point 10. A log format naming a request header would put this
# factory's credential in a log, which is the thing ADR-025 exists to keep out
# of the store and out of a build log.
@test "the proxy records what a request cost and never what it carried" {
	run proxy_log
	assert_success
	assert_output --partial '$request'
	assert_output --partial '$status'
	assert_output --partial '$request_time'
	assert_output --partial '$body_bytes_sent'
	# Request headers are where the credential is. Not one of them is named.
	refute_output --partial '$http_'
	refute_output --partial '$request_body'
	refute_output --partial '$sent_http_'
}

# Without SNI the upstream answers a TLS handshake_failure and the caller gets
# a 502 with nothing in it to explain the refusal. recommendedProxySettings
# does not set this, and it was missing for as long as the proxy existed.
@test "the proxy offers the upstream a name to answer for" {
	run proxy_log
	assert_success
	assert_output --partial "proxy_ssl_server_name on"
}

@test "the proxy says what the upstream said about its own rate limits" {
	run proxy_log
	assert_success
	assert_output --partial '$upstream_http_retry_after'
	assert_output --partial '$upstream_status'
}

## The probe unit: what it runs, where it logs, and what it is allowed to do.
probe_facts() {
	local factory="${1:-acme}"
	nix eval --raw --impure --expr '
    let
      flake = builtins.getFlake (toString '"$CAGEWORKS_ROOT"');
      m = flake.lib.machine {
        system = "aarch64-linux";
        factory = "'"$factory"'";
        sshPort = 22100;
        authorizedKey = "ssh-ed25519 AAAAtest cageworks-'"$factory"'";
      };
      c = m.config;
      u = c.systemd.services.cageworks-probes;
    in builtins.concatStringsSep "\n" [
      u.script
      (builtins.readFile c.environment.etc."cageworks/probes.bt".source)
    ]' 2>/dev/null
}

# ADR-027 point 9. The kernel answers about a role independently of the role,
# which is what makes the loop's own account checkable rather than merely
# present.
@test "the kernel is asked what a role ran, and what it opened a connection to" {
	run probe_facts
	assert_success
	assert_output --partial "sched_process_exec"
	assert_output --partial "sched_process_exit"
	assert_output --partial "tcp_connect"
}

# Orders of magnitude more traffic for a question nobody has asked.
@test "the kernel is not asked what a role opened, because nobody asked" {
	run probe_facts
	assert_success
	refute_output --partial "openat"
	refute_output --partial "sys_enter_read"
}

# Filtered where the events are, not after they arrive: a predicate compiles
# into the program, and root is the machine rather than any role.
@test "the machine's own noise is dropped in the kernel and not in a pipe" {
	run probe_facts
	assert_success
	assert_output --partial "uid != 0"
	refute_output --partial "grep"
}

# Denying a role an exec is the shape of a cage, and a cage is nixcage's.
@test "the probes observe and do not enforce" {
	run probe_facts
	assert_success
	refute_output --partial "bpf_send_signal"
	refute_output --partial "override"
	refute_output --partial "lsm:"
}

# The kernel's account goes into the same journal as the role's own, so the
# two can be read against each other without either being told about the other.

## The uid range nixcage allocates a principal from, and the proxy's own uid.
uid_range() {
	nix eval --raw --impure --expr '
    let
      flake = builtins.getFlake (toString '"$CAGEWORKS_ROOT"');
      m = flake.lib.machine {
        system = "aarch64-linux";
        factory = "acme";
        sshPort = 22100;
        authorizedKey = "ssh-ed25519 AAAAtest cageworks-acme";
      };
      c = m.config;
      r = c.nixcage.principalUidRange;
    in "${toString r.base} ${toString r.size} ${toString c.users.users.cageworks-egress.uid}"
  ' 2>/dev/null
}

# nixcage-container refuses every verb without this, so a machine that does not
# declare it is one where no role has a uid, no worktree can be asked for, and
# the ledger has nowhere to live. Found by the journal unit being the first
# thing on a factory's machine to call the primitive.
@test "the machine declares the range a principal's uid comes from" {
	run uid_range
	assert_success
	local base size proxy
	read -r base size proxy <<<"$output"
	[ "$base" -gt 0 ]
	[ "$size" -ge 1 ]
	# ADR-025 puts the proxy far below any principal range, so that a role
	# sharing its uid would be a role that may leave the machine.
	[ "$base" -gt "$proxy" ]
}

## What /etc/resolv.conf points a process at.
resolver_source() {
	nix eval --raw --impure --expr '
    let
      flake = builtins.getFlake (toString '"$CAGEWORKS_ROOT"');
      m = flake.lib.machine {
        system = "aarch64-linux";
        factory = "acme";
        sshPort = 22100;
        authorizedKey = "ssh-ed25519 AAAAtest cageworks-acme";
        egress = [ "api.anthropic.com" ];
      };
    in toString m.config.environment.etc."resolv.conf".source
  ' 2>/dev/null
}

# ADR-025 filters egress on uid. A stub resolver resolves on everybody's behalf
# under its own uid, so every name lookup on the machine becomes one daemon's
# packet: either that daemon is let out and a role has a DNS channel to the
# internet, or it is not and nothing on the machine can resolve anything. The
# second is what was happening, and it took the proxy's own upstream with it.
#
# Pointing glibc at the uplink file instead means a process resolves for
# itself, so a query is the asking uid's packet and the existing rules decide
# it. Measured on a machine: root and the proxy resolve, a role's uid does not.
@test "a name is resolved by whoever wants it, so egress rules reach DNS" {
	run resolver_source
	assert_success
	assert_output "/run/systemd/resolve/resolv.conf"
	refute_output --partial "stub-resolv.conf"
}

## Whether the machine is built with IPv6 at all.
machine_ipv6() {
	nix eval --raw --impure --expr '
    let
      flake = builtins.getFlake (toString '"$CAGEWORKS_ROOT"');
      m = flake.lib.machine {
        system = "aarch64-linux";
        factory = "acme";
        sshPort = 22100;
        authorizedKey = "ssh-ed25519 AAAAtest cageworks-acme";
        egress = [ "api.anthropic.com" ];
      };
    in if m.config.networking.enableIPv6 then "enabled" else "disabled"
  ' 2>/dev/null
}

# The machine has a link-local address and no global one, no default route and
# no way out over IPv6. A resolver that answers with both families hands the
# proxy an address it cannot reach, and every request through it fails with
# "Network is unreachable" behind a 502 the caller cannot explain.
#
# Turned off rather than routed, because ADR-025's way out is one proxy and one
# uid, and giving the machine a second address family widens what the filter
# has to be right about for no endpoint anybody declared.
@test "the machine resolves only the family it can actually reach" {
	run machine_ipv6
	assert_success
	assert_output "disabled"
}

## What the machine adds to every cage's userland.
machine_container_packages() {
	nix eval --raw --impure --expr '
    let
      flake = builtins.getFlake (toString '"$CAGEWORKS_ROOT"');
      m = flake.lib.machine {
        system = "aarch64-linux";
        factory = "acme";
        sshPort = 22100;
        authorizedKey = "ssh-ed25519 AAAAtest cageworks-acme";
      };
    in builtins.concatStringsSep " "
      (map (p: p.name or "?") m.config.nixcage.containerPackages)
  ' 2>/dev/null
}

# ADR-030 point 1. A repository that forgets the agent declares a factory whose
# roles start and immediately fail, and the operator cannot repair that without
# editing somebody else's repository. So the machine carries it, and a project
# naming its own build in a devShell shadows this rather than competing with it.
@test "every cage carries the agent, whatever the repository declares" {
	run machine_container_packages
	assert_success
	assert_output --partial "pi-coding-agent"
}

# The supervisor's git comes from the wrapper package.nix builds, so a machine
# could run a factory while an operator sshing into it had no git at all. It is
# in the closure either way; this puts it where somebody can use it.
@test "the machine carries git on its own path" {
	run machine_container_packages
	assert_success
	run nix eval --raw --impure --expr '
    let
      flake = builtins.getFlake (toString '"$CAGEWORKS_ROOT"');
      m = flake.lib.machine {
        system = "aarch64-linux";
        factory = "acme";
        sshPort = 22100;
        authorizedKey = "ssh-ed25519 AAAAtest cageworks-acme";
      };
    in builtins.concatStringsSep " "
      (map (p: p.pname or p.name or "?") m.config.environment.systemPackages)
  '
	assert_success
	assert_output --partial "git"
}

# PRD-004 phase 3 is called "the factory moves in", and this is what moving in
# means: the machine program that holds every role-, task- and factory- verb has
# to be on the machine those verbs run on. Without it the CLI reaches a machine
# that answers "cageworks-container: command not found" to everything.
@test "the machine carries the machine program the CLI talks to" {
	run nix eval --raw --impure --expr '
    let
      flake = builtins.getFlake (toString '"$CAGEWORKS_ROOT"');
      m = flake.lib.machine {
        system = "aarch64-linux";
        factory = "acme";
        sshPort = 22100;
        authorizedKey = "ssh-ed25519 AAAAtest cageworks-acme";
      };
    in builtins.concatStringsSep " "
      (map (p: p.pname or p.name or "?") m.config.environment.systemPackages)
  '
	assert_success
	assert_output --partial "cageworks-container"
}

## The nix settings the machine is built with.
machine_nix_features() {
	nix eval --raw --impure --expr '
    let
      flake = builtins.getFlake (toString '"$CAGEWORKS_ROOT"');
      m = flake.lib.machine {
        system = "aarch64-linux";
        factory = "acme";
        sshPort = 22100;
        authorizedKey = "ssh-ed25519 AAAAtest cageworks-acme";
      };
    in builtins.concatStringsSep " "
      (m.config.nix.settings.experimental-features or [ ])
  ' 2>/dev/null
}

# The supervisor reads every declaration by evaluating the repository's flake
# (ADR-020), so a machine whose nix refuses nix-command and flakes can read no
# declaration at all: no role resolves, no worktree is prepared, no session
# starts. It failed as "declares no factory", which is what nix's own refusal
# looks like once the stderr saying otherwise has been discarded.
@test "the machine's nix can evaluate the flake a declaration lives in" {
	run machine_nix_features
	assert_success
	assert_output --partial "nix-command"
	assert_output --partial "flakes"
}
