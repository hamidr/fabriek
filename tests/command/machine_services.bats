#!/usr/bin/env bats
# What the machine carries besides cages (ADR-036, ADR-037, ADR-038), as one
# image for every factory (ADR-057): the board, the bus, the bridge with its
# two rules, the counting proxy, the probes, the floor, and the seams
# factory-prepare fills at boot. Evaluated through lib.appliance for this
# host; nothing of a factory is here, and the scenarios assert that too.
# What the machine does when booted is tests/manual/isolation.sh.

load ../test_helper/common

setup() {
	setup_temp_dir
	HOST="$(nix eval --impure --raw --expr 'builtins.currentSystem')"
	MACHINE="${HOST%%-*}-linux"
}

teardown() {
	teardown_temp_dir
}

## A Nix expression over the machine's configuration, bound to c, as JSON.
machine_eval() {
	nix eval --json --impure --expr "
	  let c = ((builtins.getFlake \"path:$FABRIEK_ROOT\").lib.appliance {
	    system = \"$MACHINE\"; hostSystem = \"$HOST\";
	  }).config; in $1" 2> >(grep -v -e 'Nix search path entry' -e "^building '" >&2)
}

## What the runtime args script appends on a Linux host for memory above
## the image's own (ADR-057 point 2), and nothing elsewhere.
numa_node() {
	[[ "$HOST" == *-linux ]] || return 0
	local base
	base="$(machine_eval 'c.microvm.mem')"
	printf ' -object memory-backend-memfd,id=fabriek-mem,size=%sM,share=on -numa node,memdev=fabriek-mem' "$(($1 - base))"
}

## The same, for a string-valued attribute: the text itself, unescaped.
machine_text() {
	machine_eval "$1" | jq -r .
}

## The runtime args script, built so that it can be run here. Building it by
## its store path would find nothing when the text has changed since the
## appliance was last built.
runtime_script() {
	nix build --no-link --print-out-paths --impure --expr "
	  ((builtins.getFlake \"path:$FABRIEK_ROOT\").lib.appliance {
	    system = \"$MACHINE\"; hostSystem = \"$HOST\";
	  }).config.microvm.extraArgsScript" 2> >(grep -v -e 'Nix search path entry' -e "^building '" >&2)
}

@test "nothing of a factory, an operator or a host is in the image" {
	run machine_eval 'builtins.filter (n: builtins.match "fabriek/.*" n != null) (builtins.attrNames c.environment.etc)'
	assert_output '["fabriek/probes.bt","fabriek/spend.js"]'
	run machine_eval '[c.networking.hostName c.networking.hostId]'
	assert_output '["fabriek","fab21e57"]'
	run machine_eval '[c.microvm.interfaces c.microvm.forwardPorts (map (v: v.autoCreate) c.microvm.volumes)]'
	assert_output '[[],[],[false,false]]'
	run machine_eval 'c.services.openssh.authorizedKeysFiles'
	assert_output --partial '/run/credentials/@system/fabriek.authorized_keys'
	run machine_eval 'c.users.users.root.openssh.authorizedKeys.keys'
	assert_output '[]'
}

# ADR-057 point 1a: the host's store is the lower layer, the machine's
# builds the upper, and the overlay is the default store so a host path
# counts as valid to the daemon and to nixcage's closure query alike.
@test "the host's store is shared in as the lower layer and the overlay is the default store" {
	run machine_eval 'c.microvm.storeOnDisk'
	assert_output false
	run machine_eval 'map (s: [s.source s.mountPoint]) c.microvm.shares'
	assert_output '[["/nix/store","/nix/.ro-host/nix/store"],["/nix/var/nix/db","/nix/.ro-host-db"]]'
	run machine_eval 'c.microvm.writableStoreOverlay'
	assert_output '"/nix/.rw-store"'
	run machine_text 'c.nix.settings.store'
	assert_output --partial 'local-overlay://'
	assert_output --partial 'lower-store=local%3Froot%3D%2Fnix%2F.ro-host'
	assert_output --partial 'upper-layer=/nix/.rw-store/store&check-mount=false'
	run machine_eval 'c.nix.settings.experimental-features'
	assert_output --partial 'local-overlay-store'
}

@test "a Linux host shares over virtiofs and a macOS host over 9p" {
	run machine_eval '(builtins.head c.microvm.shares).proto'
	case "$HOST" in
	*-linux) assert_output '"virtiofs"' ;;
	*) assert_output '"9p"' ;;
	esac
}

# The host's db is shared aside and snapshotted at boot, because a store
# opened read-only ignores the host's write-ahead log and the newest paths
# are only there (measured 2026-09-16).
@test "the lower store reads a checkpointed snapshot of the host's db, taken before the daemon starts" {
	run machine_eval 'with c.systemd.services.fabriek-lower-db; { inherit before; mounts = unitConfig.RequiresMountsFor; }'
	assert_output '{"before":["nix-daemon.service","nix-daemon.socket","sysinit.target"],"mounts":["/nix/.ro-host-db","/nix/.rw-store"]}'
	run machine_text 'c.systemd.services.fabriek-lower-db.script'
	assert_output --partial "sqlite3 -readonly /nix/.ro-host-db/db.sqlite \"VACUUM INTO '/nix/.rw-store/lower-db/db.sqlite'\""
	assert_output --partial 'mount --bind /nix/.rw-store/lower-db /nix/.ro-host/nix/var/nix/db'
	run machine_eval 'c.systemd.services.nix-daemon.requires'
	assert_output '["fabriek-lower-db.service"]'
}

# fabriek up makes store.img as an empty file and never runs mkfs, so the
# machine has to: in the initrd, on the volume found by its serial, before
# the check and the mount that need a filesystem there (measured
# 2026-09-16: the first boot on a Linux host stopped in the emergency
# shell on "Can't find ext4 filesystem").
@test "the store's upper layer is formatted by the initrd at first boot, before it is checked and mounted" {
	run machine_eval 'c.fileSystems."/nix/.rw-store".device'
	assert_output '"/dev/disk/by-id/virtio-fabriek-store"'
	run machine_eval 'with c.boot.initrd.systemd.services.fabriek-store-format; { inherit before wantedBy; once = unitConfig.ConditionPathIsMountPoint; }'
	assert_output '{"before":["systemd-fsck@dev-disk-by\\x2did-virtio\\x2dfabriek\\x2dstore.service","sysroot-nix-.rw\\x2dstore.mount"],"once":"!/sysroot/nix/.rw-store","wantedBy":["initrd-fs.target"]}'
	run machine_text 'c.boot.initrd.systemd.services.fabriek-store-format.script'
	assert_output --partial 'e2label /dev/disk/by-id/virtio-fabriek-store'
	assert_output --partial 'mkfs.ext4 -q -L fabriek-store /dev/disk/by-id/virtio-fabriek-store'
}

# ADR-057 point 2: the runner is the image's; the host's facts arrive on the
# hypervisor's command line from a script that reads runtime.json where the
# runner is started.
@test "the runtime args script gives qemu the memory, the cores, the ssh port and one fw_cfg credential per file" {
	local script
	script="$(runtime_script)"
	[ -n "$script" ]
	cat >"$TEST_TEMP_DIR/runtime.json" <<'JSON'
{ "mem": 16384, "cpus": 8, "sshPort": 22100,
  "credentials": { "fabriek.toml": "fabriek.toml", "fabriek.authorized_keys": "id_ed25519.pub" } }
JSON
	run bash -c "cd '$TEST_TEMP_DIR' && bash '$script'"
	assert_success
	assert_output "-m 16384M -smp 8$(numa_node 16384) -netdev user,id=fabriek,hostfwd=tcp:127.0.0.1:22100-:22 -device virtio-net-pci,netdev=fabriek -fw_cfg name=opt/io.systemd.credentials/fabriek.toml,file=fabriek.toml -fw_cfg name=opt/io.systemd.credentials/fabriek.authorized_keys,file=id_ed25519.pub"
}

# A virtiofs share on a Linux host makes the runner back the image's memory
# with one shared memfd NUMA node, and qemu refuses a -m that the nodes do
# not sum to. The script adds a second node for the rest, so the machine
# is the size the caps allow and not the image's default (measured
# 2026-09-16: the first boot on a Linux host died on that check).
@test "on a Linux host the runtime args script adds a shared NUMA node for the memory above the image's" {
	[[ "$HOST" == *-linux ]] || skip "only a Linux host runs virtiofs"
	local script base
	script="$(runtime_script)"
	base="$(machine_eval 'c.microvm.mem')"
	cat >"$TEST_TEMP_DIR/runtime.json" <<'JSON'
{ "mem": 8192, "cpus": 4, "sshPort": 22100, "credentials": {} }
JSON
	run bash -c "cd '$TEST_TEMP_DIR' && bash '$script'"
	assert_success
	assert_output --partial " -object memory-backend-memfd,id=fabriek-mem,size=$((8192 - base))M,share=on -numa node,memdev=fabriek-mem"
	assert_output --partial "-m 8192M"
}

@test "a machine no larger than the image's memory gets no second NUMA node" {
	local script base
	script="$(runtime_script)"
	base="$(machine_eval 'c.microvm.mem')"
	printf '{ "mem": %s, "cpus": 1, "sshPort": 22100, "credentials": {} }\n' "$base" >"$TEST_TEMP_DIR/runtime.json"
	run bash -c "cd '$TEST_TEMP_DIR' && bash '$script'"
	assert_success
	refute_output --partial "numa"
}

@test "without runtime.json the runner refuses to start rather than boot a machine of default size" {
	local script
	script="$(runtime_script)"
	run bash -c "cd '$TEST_TEMP_DIR' && bash '$script'"
	assert_failure
	assert_output --partial 'no runtime.json'
}

@test "the bridge is one constant name at .1, its cages set empty for prepare to fill, and its two rules stand" {
	run machine_eval 'c.networking.interfaces.fabriek0.ipv4.addresses'
	assert_output '[{"address":"10.77.0.1","prefixLength":24}]'
	run machine_text 'c.networking.nftables.tables.fabriek-cages.content'
	assert_success
	assert_output --partial 'set cages {'
	refute_output --partial 'elements'
	assert_output --partial 'iifname "nc-*" ether type ip iifname . ip saddr != @cages drop'
	assert_output --partial 'iifname "nc-*" oifname "nc-*" drop'
	run machine_eval 'c.networking.nftables.tables.fabriek-cages.family'
	assert_output '"bridge"'
	# What the machine program renders the plan with, the same numbers the
	# services bind.
	run machine_eval 'with c.environment.variables; [FABRIEK_BRIDGE FABRIEK_BRIDGE_HOST FABRIEK_PROXY_PORT FABRIEK_FORGEJO_PORT FABRIEK_VALKEY_PORT]'
	assert_output '["fabriek0","10.77.0.1","8118","3000","6379"]'
}

# The machine's own firewall drops a new connection on any interface it was
# not told about; found on a machine where every cage's connect timed out.
@test "the machine admits a cage to the bus, the board and the proxy on the bridge, and to nothing else" {
	run machine_eval 'c.networking.firewall.interfaces.fabriek0.allowedTCPPorts'
	assert_output '[3000,6379,8118]'
	run machine_eval 'c.networking.firewall.interfaces.fabriek0.allowedUDPPorts'
	assert_output '[]'
}

@test "the machine itself still leaves only as root or as the proxy" {
	run machine_text 'c.networking.nftables.tables.fabriek-egress.content'
	assert_success
	assert_output --partial 'meta skuid 500 accept'
	assert_output --partial 'policy drop'
}

@test "the board is Forgejo on the bridge, on a dataset with a default bound prepare tightens" {
	run machine_eval 'c.services.forgejo.enable'
	assert_output true
	run machine_eval 'c.services.forgejo.settings.server.HTTP_ADDR'
	assert_output '"10.77.0.1"'
	run machine_eval 'c.services.forgejo.stateDir'
	assert_output '"/var/lib/nixcage/forgejo"'
	run machine_text 'c.systemd.services.fabriek-record.script'
	assert_output --partial 'storage ensure'
	assert_output --partial '/var/lib/nixcage/forgejo'
	assert_output --partial '4096M'
	assert_output --partial 'systemd-tmpfiles --create --prefix=/var/lib/nixcage/forgejo'
}

@test "the forge's secrets are made after the record's dataset is mounted, not beside it" {
	run machine_eval 'c.systemd.services.forgejo-secrets.after'
	assert_output --partial 'fabriek-record.service'
	run machine_eval 'c.systemd.services.forgejo-secrets.requires'
	assert_output --partial 'fabriek-record.service'
}

@test "the bus is Valkey on the bridge with no persistence, and the ACL is the machine program's, factory unnamed" {
	run machine_text 'c.systemd.services.fabriek-bus.serviceConfig.ExecStart'
	assert_output --partial 'valkey-server'
	assert_output --partial '--bind 10.77.0.1'
	assert_output --partial '--save ""'
	run machine_text 'c.systemd.services.fabriek-bus-acl.script'
	assert_success
	assert_output 'fabriek-container bus-acl'
}

# ADR-057 point 4: the ceiling and the locations are prepare's to render;
# the vhost includes whatever is there, which before prepare is nothing.
@test "the proxy listens on the bridge, counts tokens, and includes the endpoints prepare renders" {
	run machine_eval 'c.services.nginx.enable'
	assert_output true
	run machine_eval '(builtins.head c.services.nginx.virtualHosts.fabriek-egress.listen).addr'
	assert_output '"10.77.0.1"'
	run machine_eval 'map (m: m.name) c.services.nginx.additionalModules'
	assert_output --partial njs
	run machine_text 'c.services.nginx.commonHttpConfig'
	assert_output --partial 'js_shared_dict_zone zone=spend:256k type=number;'
	assert_output --partial 'js_set $spend_over'
	run machine_text 'c.services.nginx.virtualHosts.fabriek-egress.extraConfig'
	assert_output --partial 'set $spend_ceiling 0;'
	assert_output --partial 'location = /status'
	assert_output --partial 'include /var/lib/fabriek/factory/proxy/*.conf;'
	refute_output --partial 'proxy_pass'
	run machine_text 'c.environment.etc."fabriek/spend.js".text'
	assert_output --partial 'output|completion)_tokens'
}

@test "the credential headers are composed from the endpoints prepare wrote, and from nothing before it" {
	run machine_text 'c.systemd.services.fabriek-egress-credentials.script'
	assert_success
	assert_output --partial 'endpoints=/var/lib/fabriek/factory/endpoints.json'
	assert_output --partial '[ -f "$endpoints" ] || exit 0'
	assert_output --partial 'jq -r'
	refute_output --partial 'api.anthropic.com'
}

@test "the probes go through the machine program, which names the role each cgroup belongs to" {
	run machine_text 'c.systemd.services.fabriek-probes.script'
	assert_success
	assert_output --partial 'bpftrace'
	assert_output --partial '| fabriek-container probes-publish'
	refute_output --partial 'LogNamespace'
	run machine_text 'c.environment.etc."fabriek/probes.bt".text'
	assert_output --partial 'printf("exec cgroup=%d uid=%d'
}

# ADR-030, ADR-035, ADR-054: the floor is what every cage carries whatever the
# repository declares. One store path; prepare composes a role's directory
# from it and the session names it a root.
@test "the floor carries the loop, both extensions, the decider's loop and the guidance, and the machine program is told where" {
	local floor
	floor="$(machine_text 'c.environment.variables.FABRIEK_FLOOR')"
	assert_regex "$floor" '^/nix/store/.*-fabriek-floor$'
	run machine_text 'c.environment.variables.FABRIEK_ETC'
	assert_output '/var/lib/fabriek/factory'
	# And where render evaluates a profile from (ADR-057 point 5): fabriek
	# itself, in the store, for the machine's system.
	run machine_text 'c.environment.variables.FABRIEK_SELF'
	assert_regex "$output" '^/nix/store/.*-source$'
	run machine_text 'c.environment.variables.FABRIEK_NIXPKGS'
	assert_regex "$output" '^/nix/store/.*-source$'
	run machine_text 'c.environment.variables.FABRIEK_SYSTEM'
	assert_output "$MACHINE"
	run machine_eval 'map (p: p.pname or p.name) c.nixcage.containerPackages'
	assert_output --partial pi-coding-agent
	# Evaluated, not built: what the index files import is in the build
	# command's text, and that is what a cage's closure has to carry.
	run machine_text 'c.fabriek.machine.floor.buildCommand'
	assert_success
	assert_output --partial 'extensions/fabriek/index.ts'
	assert_output --partial 'extensions/pi-lsp/index.ts'
	assert_output --partial 'extensions/pi-codegraph/index.ts'
	assert_output --partial 'decider/extensions/fabriek/index.ts'
	assert_output --partial 'dist/extension/index.js'
	assert_output --partial 'dist/decider/index.js'
	assert_output --partial 'guidance.md'
}

# The lifecycle model (models/vm-lifecycle.qnt) found the mark on the pool:
# a reboot with new credentials came up prepared for the old ones.
@test "the executor waits for a mark prepare writes per boot, under /run" {
	run machine_eval 'c.systemd.services.fabriek-executor.unitConfig.ConditionPathExists'
	assert_output '"/run/fabriek/prepared"'
}
