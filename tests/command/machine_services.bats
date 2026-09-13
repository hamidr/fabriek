#!/usr/bin/env bats
# What a factory's machine carries besides cages (ADR-036, ADR-037, ADR-038):
# the board, the bus, the bridge with its two rules, the counting proxy and
# the probes. Evaluated through lib.factory against a repository declaring two
# roles, because the address plan and the rules are derived from the
# declaration and a machine with no roles would exercise none of it. What
# the machine does when booted is tests/manual/isolation.sh.

load ../test_helper/common

setup() {
	setup_temp_dir
	HOST="$(nix eval --impure --raw --expr 'builtins.currentSystem')"
	MACHINE="${HOST%%-*}-linux"
	REPO="$TEST_TEMP_DIR/acme"
	mkdir -p "$REPO"
	git init -q "$REPO"
	git -C "$REPO" config user.name factory
	git -C "$REPO" config user.email factory@invalid
	cat >"$REPO/flake.nix" <<'NIX'
{
  outputs = { self }: {
    fabriek = {
      name = "acme";
      roles.builder = { command = [ "pi" ]; provides = [ "build" ]; };
      roles.reviewer = { command = [ "pi" ]; provides = [ "review" ]; };
      workflows.ship.stages = [ { needs = "build"; } { needs = "review"; } ];
      resources = { memory = "4G"; cores = 2; recordQuota = "3G"; tokens = 500000;
                    egress = [ "api.anthropic.com" ]; };
    };
  };
}
NIX
	git -C "$REPO" add -A
	git -C "$REPO" -c commit.gpgsign=false commit -qm declare
	cat >"$TEST_TEMP_DIR/local.json" <<JSON
{ "factory": "acme", "system": "$MACHINE", "hostSystem": "$HOST",
  "sshPort": 2222, "authorizedKey": "ssh-ed25519 AAAA acme",
  "caps": { "memory": "16G", "cores": 8, "recordQuota": "8G", "tokens": 1000000,
            "egress": ["api.anthropic.com"] },
  "credentials": { "api.anthropic.com": "x-api-key" } }
JSON
}

teardown() {
	teardown_temp_dir
}

## A Nix expression over the machine's configuration, bound to c, as JSON.
machine_eval() {
	nix eval --json --impure --expr "
	  let c = ((builtins.getFlake \"path:$FABRIEK_ROOT\").lib.factory {
	    project = builtins.getFlake \"git+file://$REPO\";
	    local = $TEST_TEMP_DIR/local.json;
	  }).config; in $1" 2> >(grep -v -e 'Nix search path entry' -e "^building '" >&2)
}

## The same, for a string-valued attribute: the text itself, unescaped.
machine_text() {
	machine_eval "$1" | jq -r .
}

@test "given two roles, the bridge gives the machine one address and each cage its own" {
	run machine_eval 'c.environment.etc."fabriek/bridge.json".text'
	assert_success
	run jq -r '.bridge, .host, .cages.builder, .cages.reviewer, .cages.decider, .proxy, .forgejo, .valkey' <<<"$(jq -r . <<<"$output")"
	assert_line --index 0 fabriek-acme
	assert_line --index 1 10.77.0.1
	assert_line --index 2 10.77.0.10
	assert_line --index 3 10.77.0.11
	assert_line --index 4 10.77.0.2
	assert_line --index 5 10.77.0.1:8118
	assert_line --index 6 10.77.0.1:3000
	assert_line --index 7 10.77.0.1:6379
	run machine_eval '(builtins.head c.networking.interfaces."fabriek-acme".ipv4.addresses).address'
	assert_output '"10.77.0.1"'
	# An empty bridge has no carrier, and a port comes and goes with every
	# cage, so the address must not wait for one.
	run machine_eval 'c.systemd.network.networks."40-fabriek-acme".networkConfig.ConfigureWithoutCarrier'
	assert_output true
}

@test "the bridge drops a packet whose source is not its port's address, and drops cage to cage" {
	run machine_text 'c.networking.nftables.tables.fabriek-cages.content'
	assert_success
	# nspawn names a bridged veth's host end vb-<cage>, not ve-<cage>; a rule
	# keyed on the wrong prefix matches nothing and drops nothing.
	assert_output --partial '"vb-builder" . 10.77.0.10'
	assert_output --partial '"vb-reviewer" . 10.77.0.11'
	assert_output --partial 'iifname "vb-*" ether type ip iifname . ip saddr != @cages drop'
	assert_output --partial 'iifname "vb-*" oifname "vb-*" drop'
	refute_output --partial 've-'
	run machine_eval 'c.networking.nftables.tables.fabriek-cages.family'
	assert_output '"bridge"'
}

# The machine's own firewall drops a new connection on any interface it was
# not told about; found on a machine where every cage's connect timed out.
@test "the machine admits a cage to the bus, the board and the proxy on the bridge, and to nothing else" {
	run machine_eval 'c.networking.firewall.interfaces."fabriek-acme".allowedTCPPorts'
	assert_output '[3000,6379,8118]'
	run machine_eval 'c.networking.firewall.interfaces."fabriek-acme".allowedUDPPorts'
	assert_output '[]'
}

@test "the machine itself still leaves only as root or as the proxy" {
	run machine_text 'c.networking.nftables.tables.fabriek-egress.content'
	assert_success
	assert_output --partial 'meta skuid 500 accept'
	assert_output --partial 'policy drop'
}

@test "the board is Forgejo on the bridge, on a dataset bounded by recordQuota" {
	run machine_eval 'c.services.forgejo.enable'
	assert_output true
	run machine_eval 'c.services.forgejo.settings.server.HTTP_ADDR'
	assert_output '"10.77.0.1"'
	run machine_eval 'c.services.forgejo.stateDir'
	assert_output '"/var/lib/nixcage/forgejo"'
	run machine_text 'c.systemd.services.fabriek-record.script'
	assert_output --partial 'storage ensure'
	assert_output --partial '/var/lib/nixcage/forgejo'
	assert_output --partial '3072M'
	# The forge's directories are made by tmpfiles at boot, under the mount
	# this makes; they are made again on it.
	assert_output --partial 'systemd-tmpfiles --create --prefix=/var/lib/nixcage/forgejo'
}

@test "the journal namespace and its ledger are gone" {
	run machine_eval 'c.systemd.targets.sockets.wants'
	refute_output --partial 'journald@acme'
	run machine_eval 'c.systemd.services ? "fabriek-journal"'
	assert_output false
}

@test "the bus is Valkey on the bridge with no persistence, and every user is default-deny" {
	run machine_text 'c.systemd.services.fabriek-bus.serviceConfig.ExecStart'
	assert_output --partial 'valkey-server'
	assert_output --partial '--bind 10.77.0.1'
	assert_output --partial '--save ""'
	run machine_text 'c.systemd.services.fabriek-bus-acl.script'
	assert_success
	# The rules and the order they are applied in are the machine program's
	# (tests/command/bus_acl.bats); the machine only runs it with the bus up.
	assert_output --partial 'fabriek-container bus-acl acme'
}

@test "the proxy listens on the bridge, counts tokens per source address, and refuses at the ceiling" {
	run machine_eval '(builtins.head c.services.nginx.virtualHosts.fabriek-egress.listen).addr'
	assert_output '"10.77.0.1"'
	run machine_eval 'map (m: m.name) c.services.nginx.additionalModules'
	assert_output --partial njs
	run machine_text 'c.services.nginx.commonHttpConfig'
	assert_output --partial 'js_shared_dict_zone'
	assert_output --partial 'js_set $spend_over'
	run machine_text 'c.services.nginx.virtualHosts.fabriek-egress.extraConfig'
	assert_output --partial 'set $spend_ceiling 500000;'
	assert_output --partial 'location = /status'
	assert_output --partial 'js_body_filter'
	assert_output --partial 'return 429'
	run machine_text 'c.environment.etc."fabriek/spend.js".text'
	assert_output --partial 'output_tokens'
	assert_output --partial 'input_tokens'
	assert_output --partial 'remote_addr'
}

@test "the probes go through the machine program, which names the role each uid belongs to" {
	run machine_text 'c.systemd.services.fabriek-probes.script'
	assert_success
	assert_output --partial 'bpftrace'
	assert_output --partial '| fabriek-container probes-publish acme'
	refute_output --partial 'LogNamespace'
}

# A cage binds the directory and has no /etc/static of its own, so a symlink
# there is a file the cage cannot open: the decider's pi directory is real
# files, and a role's is one store path the machine program resolves.
@test "the decider's loop and models.json reach its cage as files, not as symlinks into an /etc it does not have" {
	local f
	for f in pi-decider/extensions/fabriek/index.ts pi-decider/models.json; do
		run machine_eval "c.environment.etc.\"fabriek/$f\".mode"
		assert_output '"0444"'
	done
}

# Who a role is rides in the directory pi already reads (ADR-042 point 5):
# one per role, from the store, beside its profile. The shared one is gone,
# because a directory every role read could carry no role's prompt.
@test "each role is handed its own pi directory from the store, and the shared one is gone" {
	local r
	for r in builder reviewer; do
		run machine_eval "c.environment.etc.\"fabriek/roles/$r/pi\".source"
		assert_success
		assert_output --partial "fabriek-pi-$r"
	done
	run machine_eval 'c.environment.etc ? "fabriek/pi/settings.json"'
	assert_output false
}

# ADR-043: the language-server extension rides beside the loop, loaded the
# same way, and reads the servers the role's specialists declared.
@test "a role's pi directory carries pi-lsp beside the loop and links the specialists' lsp.json" {
	run machine_text 'c.environment.etc."fabriek/roles/builder/pi".source.buildCommand'
	assert_success
	assert_output --partial 'extensions/pi-lsp/index.ts'
	assert_output --partial 'pi-lsp-0.1.7/lib/node_modules/pi-lsp/extensions/pi-lsp/index.ts'
	assert_output --partial 'share/fabriek/specialist/lsp.json $out/lsp.json'
}

# pi starts on no model unless told one, and asks before trusting a
# project's own .pi; a session with nobody at the keyboard needs both
# answered. Found on a machine whose decider said "No API key found for the
# selected model" every thirty seconds.
@test "every supervised session starts on a model of the routed provider and trusts no project settings" {
	run machine_text 'c.environment.etc."fabriek/pi-decider/settings.json".text'
	assert_output --partial '"defaultProvider":"anthropic"'
	assert_output --partial '"defaultModel":"claude-sonnet-4-5"'
	assert_output --partial '"defaultProjectTrust":"never"'
	run machine_eval 'c.environment.etc."fabriek/pi-decider/settings.json".mode'
	assert_output '"0444"'
}

@test "the executor does not start until the machine has been prepared, and is restarted when it is" {
	run machine_eval 'c.systemd.services.fabriek-executor.unitConfig.ConditionPathExists'
	assert_output '"/var/lib/nixcage/prepared"'
}

@test "the declaration is on the machine as a file, and the machine's options carry it" {
	run machine_eval 'builtins.attrNames c.fabriek.machine.declaration.roles'
	assert_output '["builder","reviewer"]'
	run machine_eval '(builtins.fromJSON c.environment.etc."fabriek/declaration.json".text).resources.tokens'
	assert_output 500000
}

@test "every supervised session is handed the loop and a models.json that points pi at the proxy" {
	run machine_text 'c.environment.etc."fabriek/pi-decider/extensions/fabriek/index.ts".text'
	assert_output --partial 'fabriek-factory'
	assert_output --partial 'dist/decider/index.js'
	run machine_text 'c.environment.etc."fabriek/pi-decider/models.json".text'
	assert_output --partial '"anthropic":{"apiKey":"fabriek","baseUrl":"http://10.77.0.1:8118/api.anthropic.com"}'
	refute_output --partial openai
	run machine_eval 'map (p: p.pname or p.name) c.nixcage.containerPackages'
	assert_output --partial pi-coding-agent
}
