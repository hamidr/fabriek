#!/usr/bin/env bats
# The machine a factory runs in (ADR-019), as the one appliance every factory
# boots (ADR-057). One evaluation per group, several assertions: evaluating a
# NixOS configuration is the only way to test a NixOS module, and it is slow
# enough that asking it eight questions at once is worth more than eight
# tests that each ask one. What is a factory's (its name, its endpoints, its
# roles) is not here any more: prepare renders it at boot, and
# tests/unit/factory_render.bats and tests/command/render.bats hold that.

load ../test_helper/common

setup() {
	setup_temp_dir
}

teardown() {
	teardown_temp_dir
}

## A Nix expression over the appliance's configuration, bound to c.
appliance_eval() {
	nix eval --raw --impure --expr '
    let
      flake = builtins.getFlake (toString '"$FABRIEK_ROOT"');
      c = (flake.lib.appliance { system = "aarch64-linux"; hostSystem = "aarch64-linux"; }).config;
    in '"$1" 2>/dev/null
}

## Every fact this file asserts about identity and storage, tab separated.
machine_facts() {
	appliance_eval '
    let pool = builtins.elemAt (builtins.filter (v: v.mountPoint == null) c.microvm.volumes) 0;
    in builtins.concatStringsSep "\t" [
      c.networking.hostName
      c.networking.hostId
      c.nixcage.storage.dataset
      pool.serial
      (toString (builtins.length c.microvm.volumes))
      (if c.boot.zfs.forceImportRoot then "forces" else "refuses")
      (if c.services.openssh.settings.PasswordAuthentication then "passwords" else "keys-only")
      (builtins.head c.services.openssh.hostKeys).path
    ]'
}

field() {
	printf '%s' "$1" | cut -f"$2"
}

@test "one machine, one identity, and the pool found by serial" {
	local facts
	facts="$(machine_facts)"
	[ -n "$facts" ]
	# One image runs one factory, so the names need no factory in them; a
	# pool made by this image imports on any machine running it.
	[ "$(field "$facts" 1)" = "fabriek" ]
	[ "$(field "$facts" 2)" = "fab21e57" ]
	[ "$(field "$facts" 3)" = "fabriek/state" ]
	# Found by serial, because a drive letter moves when the volume list does
	# and the pool would then be created on top of the store.
	[ "$(field "$facts" 4)" = "fabriek-pool" ]
	# The store overlay and the pool, made by up; the host's store is shared
	# in read-only as the lower layer.
	[ "$(field "$facts" 5)" = "2" ]
}

# ADR-019 point 4: fabriek owns the way in because it owns the VM, and it is
# one key per factory with nothing else accepted; the key arrives as a
# credential at boot (ADR-057).
@test "one key reaches a machine, and a password reaches none" {
	local facts
	facts="$(machine_facts)"
	[ "$(field "$facts" 7)" = "keys-only" ]
	run appliance_eval 'builtins.head c.services.openssh.authorizedKeysFiles'
	assert_output "/run/credentials/@system/fabriek.authorized_keys"
}

# A machine that generates host keys every boot is a different machine every
# boot, and fabriek pins what it connected to.
@test "a machine keeps its identity across a stop, because its keys persist" {
	local facts
	facts="$(machine_facts)"
	[ "$(field "$facts" 8)" = "/var/lib/nixcage/ssh/ssh_host_ed25519_key" ]
}

# ADR-017 exists because worktrees came back empty. Forcing an import is how a
# pool that should have been looked at is adopted instead.
@test "a pool that will not import cleanly is a fault, not a device to adopt" {
	local facts
	facts="$(machine_facts)"
	[ "$(field "$facts" 6)" = "refuses" ]
}

# ADR-025: a cage holds no credential and no route. The firewall is where the
# second half of that is true, and it filters on the uid a session's processes
# carry rather than on a host, because a packet filter cannot resolve a name
# and the allowlist is names.
egress_ruleset() {
	appliance_eval 'c.networking.nftables.tables.fabriek-egress.content'
}

@test "a machine drops egress by default, so a uid nobody allowed reaches nothing" {
	run egress_ruleset
	assert_success
	assert_output --partial "hook output"
	assert_output --partial "policy drop"
}

@test "the proxy is the one uid that may leave the machine on a factory's behalf" {
	run egress_ruleset
	assert_success
	assert_output --partial "meta skuid 500 accept"
	assert_output --partial "meta skuid 0 accept"
}

@test "a role reaches the proxy, which is on the machine, so loopback and the bridge stay open" {
	run egress_ruleset
	assert_success
	assert_output --partial 'oifname "lo" accept'
	assert_output --partial 'oifname "fabriek-*" accept'
}

@test "no rule names a role, because a role is denied by there being no rule for it" {
	run egress_ruleset
	assert_success
	refute_output --partial "700000"
	refute_output --partial "builder"
}

@test "the machine has a user for the proxy to be, separate from root and from every role" {
	run appliance_eval 'toString c.users.users.fabriek-egress.uid'
	assert_output 500
	run appliance_eval 'c.services.nginx.user'
	assert_output fabriek-egress
}

## What the proxy is configured to write about a request, and where.
proxy_log() {
	appliance_eval 'c.services.nginx.commonHttpConfig + c.services.nginx.virtualHosts."fabriek-egress".extraConfig'
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
	refute_output --partial '$http_'
	refute_output --partial '$request_body'
	refute_output --partial '$sent_http_'
}

@test "the proxy says what the upstream said about its own rate limits" {
	run proxy_log
	assert_success
	assert_output --partial '$upstream_http_retry_after'
	assert_output --partial '$upstream_status'
}

# ADR-018. The operator names a host and pipes a secret; where it lands is the
# machine's business. Without this command the CLI would be calling something
# that is not there.
@test "every machine knows how to be handed a credential, since which endpoints it reaches is decided at boot" {
	run appliance_eval 'builtins.concatStringsSep "\n" (map (p: p.name or "") c.environment.systemPackages)'
	assert_success
	assert_line "fabriek-egress-credential"
}

## The probe unit: what it runs, where it logs, and what it is allowed to do.
probe_facts() {
	appliance_eval 'builtins.concatStringsSep "\n" [
      c.systemd.services.fabriek-probes.script
      (builtins.readFile c.environment.etc."fabriek/probes.bt".source)
    ]'
}

# ADR-027 point 9. The kernel answers about a role independently of the role.
@test "the kernel is asked what a role ran, and what it opened a connection to" {
	run probe_facts
	assert_success
	assert_output --partial "sched_process_exec"
	assert_output --partial "sched_process_exit"
	assert_output --partial "tcp_connect"
}

@test "the kernel is not asked what a role opened, because nobody asked" {
	run probe_facts
	assert_success
	refute_output --partial "openat"
	refute_output --partial "sys_enter_read"
}

@test "the machine's own noise is dropped in the kernel and not in a pipe" {
	run probe_facts
	assert_success
	assert_output --partial "uid != 0"
	refute_output --partial "grep"
}

@test "the probes observe and do not enforce" {
	run probe_facts
	assert_success
	refute_output --partial "bpf_send_signal"
	refute_output --partial "override"
	refute_output --partial "lsm:"
}

# nixcage-container refuses every verb without this, so a machine that does not
# declare it is one where no role has a uid and no worktree can be asked for.
@test "the machine declares the range a principal's uid comes from, above the proxy's" {
	run appliance_eval 'let r = c.nixcage.principalUidRange; in "${toString r.base} ${toString r.size} ${toString c.users.users.fabriek-egress.uid}"'
	assert_success
	local base size proxy
	read -r base size proxy <<<"$output"
	[ "$base" -gt 0 ]
	[ "$size" -ge 1 ]
	[ "$base" -gt "$proxy" ]
}

# ADR-025 filters egress on uid. A stub resolver would resolve on everybody's
# behalf under its own uid; glibc reading the uplink file resolves in the
# asking process, so a query is that uid's packet.
@test "a name is resolved by whoever wants it, so egress rules reach DNS" {
	run appliance_eval 'toString c.environment.etc."resolv.conf".source'
	assert_success
	assert_output "/run/systemd/resolve/resolv.conf"
}

@test "the machine resolves only the family it can actually reach" {
	run appliance_eval 'if c.networking.enableIPv6 then "enabled" else "disabled"'
	assert_output disabled
}

@test "every cage carries the agent, whatever the repository declares" {
	run appliance_eval 'builtins.concatStringsSep "\n" (map (p: p.pname or p.name) c.nixcage.containerPackages)'
	assert_output --partial pi-coding-agent
}

@test "the machine carries git and the machine program on its own path" {
	run appliance_eval 'builtins.concatStringsSep "\n" (map (p: p.pname or p.name or "") c.environment.systemPackages)'
	assert_output --partial git
	assert_output --partial fabriek-container
}

# ADR-057 point 5: prepare has the machine's own daemon build each role's
# profile from the repository at the pin, which needs flakes, and the
# overlay store over the host's, which is experimental in this nix.
@test "the machine's nix can build a profile from a flake at the pin, over the host's store" {
	run appliance_eval 'builtins.concatStringsSep " " c.nix.settings.experimental-features'
	assert_output --partial "nix-command"
	assert_output --partial "flakes"
	assert_output --partial "local-overlay-store"
}
