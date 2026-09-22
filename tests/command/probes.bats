#!/usr/bin/env bats
# What the kernel says a role ran, onto the bus (ADR-038 point 3): each
# bpftrace line becomes one entry on the probes stream of the factory whose
# cage the cgroup is, written as that factory's probes user, carrying the
# cgroup the kernel saw and the role, which nixcage says from the cage's
# scope (nixcage ADR-012). One reader serves every factory on the host
# (ADR-067): the factories are the facts files the host wrote. natscli and
# nixcage-container are stubbed; the cgroup tree is a fixture.

load ../test_helper/common

setup() {
	setup_temp_dir
	STUB_DIR="$TEST_TEMP_DIR/bin"
	FACTS="$TEST_TEMP_DIR/facts"
	mkdir -p "$STUB_DIR" "$FACTS"
	PATH="$STUB_DIR:$PATH"
	export PATH FABRIEK_FACTORIES="$FACTS"
	# Two factories, each with its state, its rendered directory and its
	# bus; widgets has no declaration yet, which is a factory never brought
	# up, and owns no cage.
	factory acme 0 '"builder": { "command": ["pi"], "provides": ["build"] }, "reviewer": { "command": ["pi"], "provides": ["review"] }'
	factory widgets 1 ""
	STATE="$TEST_TEMP_DIR/acme/state"
	cat >"$STUB_DIR/nats" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$* url=\${NATS_URL:-} user=\${NATS_USER:-}" >>"$TEST_TEMP_DIR/bus-calls"
printf '%s\n' "\${NATS_PASSWORD:-}" >>"$TEST_TEMP_DIR/bus-auth"
STUB
	# Each running cage's scope, asked by name; a role whose cage is not
	# running is stopped and owns no cgroup.
	export FABRIEK_CGROUP_ROOT="$TEST_TEMP_DIR/cgroup"
	mkdir -p "$FABRIEK_CGROUP_ROOT/machine.slice/machine-acme-builder.scope" "$FABRIEK_CGROUP_ROOT/machine.slice/machine-acme-decider.scope"
	BUILDER_CG="$(inode "$FABRIEK_CGROUP_ROOT/machine.slice/machine-acme-builder.scope")"
	DECIDER_CG="$(inode "$FABRIEK_CGROUP_ROOT/machine.slice/machine-acme-decider.scope")"
	cat >"$STUB_DIR/nixcage-container" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TEST_TEMP_DIR/status-calls"
case "\$2" in acme-builder) echo "running 4001 machine.slice/machine-acme-builder.scope" ;; acme-decider) echo "running 4002 machine.slice/machine-acme-decider.scope" ;; *) echo stopped ;; esac
STUB
	chmod +x "$STUB_DIR/nats" "$STUB_DIR/nixcage-container"
}

## One factory on the host: its facts file, and what render and prepare
## left under its directories (a declaration when given, and a bridge
## plan at its own subnet).
## factory <name> <idx> <roles-json-or-empty>
factory() {
	local name="$1" idx="$2" roles="$3"
	local dir="$TEST_TEMP_DIR/$name"
	mkdir -p "$dir/state/bus" "$dir/etc"
	cat >"$FACTS/$name.env" <<EOF
FABRIEK_FACTORY=$name
FABRIEK_BRIDGE=fb-$idx
FABRIEK_BRIDGE_HOST=10.77.$idx.1
FABRIEK_STATE=$dir/state
FABRIEK_ETC=$dir/etc
EOF
	cat >"$dir/etc/bridge.json" <<JSON
{ "bridge": "fb-$idx", "host": "10.77.$idx.1", "prefix": 24,
  "cages": { "builder": "10.77.$idx.10", "reviewer": "10.77.$idx.11", "decider": "10.77.$idx.2" },
  "proxy": "10.77.$idx.1:8118", "forgejo": "10.77.$idx.1:3000", "bus": "10.77.$idx.1:4222" }
JSON
	[ -n "$roles" ] || return 0
	cat >"$dir/etc/declaration.json" <<JSON
{ "name": "$name", "roles": { $roles },
  "workflows": { "ship": { "stages": [ { "needs": "build" }, { "needs": "review" } ] } } }
JSON
}

## A directory's inode, which is what the kernel calls its cgroup's id.
inode() {
	stat -c %i "$1"
}

teardown() {
	teardown_temp_dir
}

publish() {
	bash "$FABRIEK_CONTAINER_BIN" probes-publish
}

@test "given a bus password, each kernel line is one entry on the probes stream with its cgroup, its role and the line" {
	echo probes-pass >"$STATE/bus/probes"
	run publish <<LINES
exec cgroup=$BUILDER_CG uid=60000 pid=4242 comm=git
connect cgroup=$DECIDER_CG uid=60192 pid=4300 comm=node
LINES
	assert_success
	run cat "$TEST_TEMP_DIR/bus-calls"
	assert_line --index 0 --partial "url=nats://10.77.0.1:4222 user=acme-probes"
	run bash -c "sed -n '1p' '$TEST_TEMP_DIR/bus-calls' | sed 's/^pub probes //; s/ url=.*//' | jq -r '[.cgroup, .role, .event] | join(\"|\")'"
	assert_output "$BUILDER_CG|builder|exec cgroup=$BUILDER_CG uid=60000 pid=4242 comm=git"
	run bash -c "sed -n '2p' '$TEST_TEMP_DIR/bus-calls' | sed 's/^pub probes //; s/ url=.*//' | jq -r '[.cgroup, .role] | join(\"|\")'"
	assert_output "$DECIDER_CG|decider"
}

# nspawn runs the cage's payload in a child cgroup of its scope, so the id
# the kernel stamps on a process is the child's and not the scope's
# (measured 2026-09-16: every probe of a cage carried an empty role).
@test "a process in a child cgroup of a cage's scope is that cage's" {
	echo probes-pass >"$STATE/bus/probes"
	mkdir -p "$FABRIEK_CGROUP_ROOT/machine.slice/machine-acme-builder.scope/payload" "$FABRIEK_CGROUP_ROOT/machine.slice/machine-acme-builder.scope/supervisor"
	local payload
	payload="$(inode "$FABRIEK_CGROUP_ROOT/machine.slice/machine-acme-builder.scope/payload")"
	run publish <<LINES
exec cgroup=$payload uid=60000 pid=4242 comm=git
LINES
	assert_success
	run bash -c "sed 's/^pub probes //; s/ url=.*//' '$TEST_TEMP_DIR/bus-calls' | jq -r '[.cgroup, .role] | join(\"|\")'"
	assert_line --index 0 "$payload|builder"
}

@test "the entry is written as the probes user, with the password in the environment and not on argv" {
	echo probes-pass >"$STATE/bus/probes"
	run publish <<<"exec cgroup=$BUILDER_CG uid=60000 pid=1 comm=sh"
	assert_success
	run cat "$TEST_TEMP_DIR/bus-calls"
	assert_output --partial "user=acme-probes"
	refute_output --partial "probes-pass"
	run cat "$TEST_TEMP_DIR/bus-auth"
	assert_output "probes-pass"
}

# A line no factory's cage owns is the host's own (a service, a shell) and
# goes to the journal: with several factories there is no one bus to hold
# it, and the operator's watch over a factory reads that factory's cages.
@test "a cgroup no cage owns goes to stdout with an empty role, on no factory's bus" {
	echo probes-pass >"$STATE/bus/probes"
	run publish <<<"exec cgroup=999 uid=999 pid=1 comm=forgejo"
	assert_success
	assert_output "exec cgroup=999 uid=999 pid=1 comm=forgejo"
	[ ! -f "$TEST_TEMP_DIR/bus-calls" ]
}

@test "two factories' cages are told apart, and each line reaches its own factory's bus as its own probes user" {
	echo probes-pass >"$STATE/bus/probes"
	echo widgets-pass >"$TEST_TEMP_DIR/widgets/state/bus/probes"
	factory widgets 1 '"builder": { "command": ["pi"], "provides": ["build"] }'
	mkdir -p "$FABRIEK_CGROUP_ROOT/machine.slice/machine-widgets-builder.scope"
	local wcg
	wcg="$(inode "$FABRIEK_CGROUP_ROOT/machine.slice/machine-widgets-builder.scope")"
	cat >"$STUB_DIR/nixcage-container" <<STUB
#!/usr/bin/env bash
case "\$2" in acme-builder) echo "running 4001 machine.slice/machine-acme-builder.scope" ;; widgets-builder) echo "running 4003 machine.slice/machine-widgets-builder.scope" ;; *) echo stopped ;; esac
STUB
	run publish <<LINES
exec cgroup=$BUILDER_CG uid=60000 pid=1 comm=a
exec cgroup=$wcg uid=60300 pid=2 comm=b
LINES
	assert_success
	run cat "$TEST_TEMP_DIR/bus-calls"
	assert_line --index 0 --partial "url=nats://10.77.0.1:4222 user=acme-probes"
	assert_line --index 0 --partial "\"cgroup\":\"$BUILDER_CG\",\"role\":\"builder\""
	assert_line --index 1 --partial "url=nats://10.77.1.1:4222 user=widgets-probes"
	assert_line --index 1 --partial "\"cgroup\":\"$wcg\",\"role\":\"builder\""
	run cat "$TEST_TEMP_DIR/bus-auth"
	assert_output "probes-pass
widgets-pass"
}

@test "a process that changed uid inside a cage is still that cage's" {
	echo probes-pass >"$STATE/bus/probes"
	run publish <<<"exec cgroup=$BUILDER_CG uid=0 pid=7 comm=setpriv"
	assert_success
	run cat "$TEST_TEMP_DIR/bus-calls"
	assert_output --partial '"role":"builder"'
}

@test "the host is asked for each declared role's scope once, not once per line, and for no role of a factory never rendered" {
	echo probes-pass >"$STATE/bus/probes"
	run publish <<LINES
exec cgroup=$BUILDER_CG uid=60000 pid=1 comm=a
exec cgroup=$BUILDER_CG uid=60000 pid=2 comm=b
exec cgroup=$DECIDER_CG uid=60192 pid=3 comm=c
LINES
	assert_success
	run sort "$TEST_TEMP_DIR/status-calls"
	assert_output "status acme-builder
status acme-decider
status acme-reviewer"
}

@test "before a factory's bus has a password for the probes, its lines go to stdout instead" {
	run publish <<<"exec cgroup=$BUILDER_CG uid=60000 pid=1 comm=sh"
	assert_success
	assert_output "exec cgroup=$BUILDER_CG uid=60000 pid=1 comm=sh"
	[ ! -f "$TEST_TEMP_DIR/bus-calls" ]
}
