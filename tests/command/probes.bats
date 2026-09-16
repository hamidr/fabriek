#!/usr/bin/env bats
# What the kernel says a role ran, onto the bus (ADR-038 point 3): each
# bpftrace line becomes one entry on the probes stream, written as the probes
# user, carrying the cgroup the kernel saw and the role whose cage that is,
# which nixcage says from the cage's scope (nixcage ADR-012). valkey-cli and
# nixcage-container are stubbed; the cgroup tree is a fixture.

load ../test_helper/common

setup() {
	setup_temp_dir
	STATE="$TEST_TEMP_DIR/state"
	STUB_DIR="$TEST_TEMP_DIR/bin"
	ETC="$TEST_TEMP_DIR/etc"
	mkdir -p "$STATE/bus" "$STUB_DIR" "$ETC"
	PATH="$STUB_DIR:$PATH"
	export PATH STATE FABRIEK_STATE="$STATE" FABRIEK_ETC="$ETC"
	cat >"$ETC/bridge.json" <<'JSON'
{ "bridge": "fabriek-acme", "host": "10.77.0.1", "prefix": 24,
  "cages": { "builder": "10.77.0.10", "reviewer": "10.77.0.11", "decider": "10.77.0.2" },
  "proxy": "10.77.0.1:8118", "forgejo": "10.77.0.1:3000", "valkey": "10.77.0.1:6379" }
JSON
	cat >"$ETC/declaration.json" <<'JSON'
{ "name": "acme",
  "roles": { "builder": { "command": ["pi"], "provides": ["build"] },
             "reviewer": { "command": ["pi"], "provides": ["review"] } },
  "workflows": { "ship": { "stages": [ { "needs": "build" }, { "needs": "review" } ] } } }
JSON
	cat >"$STUB_DIR/valkey-cli" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TEST_TEMP_DIR/bus-calls"
printf '%s\n' "\${VALKEYCLI_AUTH:-}" >>"$TEST_TEMP_DIR/bus-auth"
echo "1-0"
STUB
	# Each running cage's scope, asked by name; a role whose cage is not
	# running is stopped and owns no cgroup.
	export FABRIEK_CGROUP_ROOT="$TEST_TEMP_DIR/cgroup"
	mkdir -p "$FABRIEK_CGROUP_ROOT/machine.slice/machine-builder.scope" "$FABRIEK_CGROUP_ROOT/machine.slice/machine-decider.scope"
	BUILDER_CG="$(inode "$FABRIEK_CGROUP_ROOT/machine.slice/machine-builder.scope")"
	DECIDER_CG="$(inode "$FABRIEK_CGROUP_ROOT/machine.slice/machine-decider.scope")"
	cat >"$STUB_DIR/nixcage-container" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TEST_TEMP_DIR/status-calls"
case "\$2" in builder) echo "running 4001 machine.slice/machine-builder.scope" ;; decider) echo "running 4002 machine.slice/machine-decider.scope" ;; *) echo stopped ;; esac
STUB
	chmod +x "$STUB_DIR/valkey-cli" "$STUB_DIR/nixcage-container"
}

## A directory's inode, which is what the kernel calls its cgroup's id.
inode() {
	stat -c %i "$1"
}

teardown() {
	teardown_temp_dir
}

publish() {
	bash "$FABRIEK_CONTAINER_BIN" probes-publish acme
}

@test "given a bus password, each kernel line is one entry on the probes stream with its cgroup, its role and the line" {
	echo probes-pass >"$STATE/bus/probes"
	run publish <<LINES
exec cgroup=$BUILDER_CG uid=60000 pid=4242 comm=git
connect cgroup=$DECIDER_CG uid=60192 pid=4300 comm=node
LINES
	assert_success
	run cat "$TEST_TEMP_DIR/bus-calls"
	assert_line --index 0 --partial "XADD probes MAXLEN ~ 10000 * cgroup $BUILDER_CG role builder event exec cgroup=$BUILDER_CG uid=60000 pid=4242 comm=git"
	assert_line --index 1 --partial "cgroup $DECIDER_CG role decider event connect cgroup=$DECIDER_CG uid=60192 pid=4300 comm=node"
}

# nspawn runs the cage's payload in a child cgroup of its scope, so the id
# the kernel stamps on a process is the child's and not the scope's
# (measured 2026-09-16: every probe of a cage carried an empty role).
@test "a process in a child cgroup of a cage's scope is that cage's" {
	echo probes-pass >"$STATE/bus/probes"
	mkdir -p "$FABRIEK_CGROUP_ROOT/machine.slice/machine-builder.scope/payload" "$FABRIEK_CGROUP_ROOT/machine.slice/machine-builder.scope/supervisor"
	local payload
	payload="$(inode "$FABRIEK_CGROUP_ROOT/machine.slice/machine-builder.scope/payload")"
	run publish <<LINES
exec cgroup=$payload uid=60000 pid=4242 comm=git
LINES
	assert_success
	run cat "$TEST_TEMP_DIR/bus-calls"
	assert_line --index 0 --partial "cgroup $payload role builder event"
}

@test "the entry is written as the probes user, with the password in the environment and not on argv" {
	echo probes-pass >"$STATE/bus/probes"
	run publish <<<"exec cgroup=$BUILDER_CG uid=60000 pid=1 comm=sh"
	assert_success
	run cat "$TEST_TEMP_DIR/bus-calls"
	assert_output --partial "--user probes"
	refute_output --partial "probes-pass"
	run cat "$TEST_TEMP_DIR/bus-auth"
	assert_output "probes-pass"
}

@test "a cgroup no cage owns is published with an empty role rather than dropped" {
	echo probes-pass >"$STATE/bus/probes"
	run publish <<<"exec cgroup=999 uid=999 pid=1 comm=forgejo"
	assert_success
	run cat "$TEST_TEMP_DIR/bus-calls"
	assert_output --partial "cgroup 999 role  event exec cgroup=999"
}

@test "a process that changed uid inside a cage is still that cage's" {
	echo probes-pass >"$STATE/bus/probes"
	run publish <<<"exec cgroup=$BUILDER_CG uid=0 pid=7 comm=setpriv"
	assert_success
	run cat "$TEST_TEMP_DIR/bus-calls"
	assert_output --partial "role builder"
}

@test "the machine is asked for each role's scope once, not once per line" {
	echo probes-pass >"$STATE/bus/probes"
	run publish <<LINES
exec cgroup=$BUILDER_CG uid=60000 pid=1 comm=a
exec cgroup=$BUILDER_CG uid=60000 pid=2 comm=b
exec cgroup=$DECIDER_CG uid=60192 pid=3 comm=c
LINES
	assert_success
	run sort "$TEST_TEMP_DIR/status-calls"
	assert_output "status builder
status decider
status reviewer"
}

@test "before the bus has a password for the probes, the lines go to stdout instead" {
	run publish <<<"exec cgroup=$BUILDER_CG uid=60000 pid=1 comm=sh"
	assert_success
	assert_output "exec cgroup=$BUILDER_CG uid=60000 pid=1 comm=sh"
	[ ! -f "$TEST_TEMP_DIR/bus-calls" ]
}
