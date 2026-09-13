#!/usr/bin/env bats
# What the kernel says a role ran, onto the bus (ADR-038 point 3): each
# bpftrace line becomes one entry on the probes stream, written as the probes
# user, carrying the uid the kernel saw and the role that uid belongs to,
# which only the machine can say. valkey-cli and nixcage-container are stubbed.

load ../test_helper/common

setup() {
	setup_temp_dir
	STATE="$TEST_TEMP_DIR/state"
	STUB_DIR="$TEST_TEMP_DIR/bin"
	ETC="$TEST_TEMP_DIR/etc"
	mkdir -p "$STATE/bus" "$STUB_DIR" "$ETC"
	PATH="$STUB_DIR:$PATH"
	export PATH STATE CAGEWORKS_STATE="$STATE" CAGEWORKS_ETC="$ETC"
	cat >"$ETC/bridge.json" <<'JSON'
{ "bridge": "cageworks-acme", "host": "10.77.0.1", "prefix": 24,
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
	# The uids the machine allocated, asked by name; a role not yet made has none.
	cat >"$STUB_DIR/nixcage-container" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TEST_TEMP_DIR/uid-calls"
case "\$2" in builder) echo 60000 ;; reviewer) echo 60064 ;; decider) echo 60192 ;; *) exit 1 ;; esac
STUB
	chmod +x "$STUB_DIR/valkey-cli" "$STUB_DIR/nixcage-container"
}

teardown() {
	teardown_temp_dir
}

publish() {
	bash "$CAGEWORKS_CONTAINER_BIN" probes-publish acme
}

@test "given a bus password, each kernel line is one entry on the probes stream with its uid, its role and the line" {
	echo probes-pass >"$STATE/bus/probes"
	run publish <<'LINES'
exec uid=60000 pid=4242 comm=git
connect uid=60192 pid=4300 comm=node
LINES
	assert_success
	run cat "$TEST_TEMP_DIR/bus-calls"
	assert_line --index 0 --partial "XADD probes MAXLEN ~ 10000 * uid 60000 role builder event exec uid=60000 pid=4242 comm=git"
	assert_line --index 1 --partial "uid 60192 role decider event connect uid=60192 pid=4300 comm=node"
}

@test "the entry is written as the probes user, with the password in the environment and not on argv" {
	echo probes-pass >"$STATE/bus/probes"
	run publish <<<"exec uid=60000 pid=1 comm=sh"
	assert_success
	run cat "$TEST_TEMP_DIR/bus-calls"
	assert_output --partial "--user probes"
	refute_output --partial "probes-pass"
	run cat "$TEST_TEMP_DIR/bus-auth"
	assert_output "probes-pass"
}

@test "a uid no role owns is published with an empty role rather than dropped" {
	echo probes-pass >"$STATE/bus/probes"
	run publish <<<"exec uid=999 pid=1 comm=forgejo"
	assert_success
	run cat "$TEST_TEMP_DIR/bus-calls"
	assert_output --partial "uid 999 role  event exec uid=999"
}

@test "the machine is asked for each role's uid once, not once per line" {
	echo probes-pass >"$STATE/bus/probes"
	run publish <<'LINES'
exec uid=60000 pid=1 comm=a
exec uid=60000 pid=2 comm=b
exec uid=60064 pid=3 comm=c
LINES
	assert_success
	run sort "$TEST_TEMP_DIR/uid-calls"
	assert_output "uid builder
uid decider
uid reviewer"
}

@test "before the bus has a password for the probes, the lines go to stdout instead" {
	run publish <<<"exec uid=60000 pid=1 comm=sh"
	assert_success
	assert_output "exec uid=60000 pid=1 comm=sh"
	[ ! -f "$TEST_TEMP_DIR/bus-calls" ]
}
