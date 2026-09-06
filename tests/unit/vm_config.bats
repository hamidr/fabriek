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
