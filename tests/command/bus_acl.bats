#!/usr/bin/env bats
# Who may say what on the bus (ADR-033 point 3): one ACL user per actor,
# default-deny and then the stream verbs it needs, read and write patterns
# kept apart, applied from the password files prepare wrote and applied
# again on request. valkey-cli is stubbed and records what it was asked; the
# password it was given reaches it through the environment and not argv.

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
	for u in builder reviewer decider executor probes; do echo "pw-$u" >"$STATE/bus/$u"; done
	# A bus whose default user is on until told otherwise, unless a test says
	# it is already off, in which case an unauthenticated ping gets NOAUTH.
	cat >"$STUB_DIR/valkey-cli" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TEST_TEMP_DIR/bus-calls"
printf '%s\n' "\${VALKEYCLI_AUTH:-}" >>"$TEST_TEMP_DIR/bus-auth"
case "\$*" in
*" ping"|ping) if [ -e "$TEST_TEMP_DIR/default-off" ] && ! printf '%s' "\$*" | grep -q -- '--user executor'; then echo "NOAUTH Authentication required."; else echo PONG; fi ;;
*) echo OK ;;
esac
STUB
	chmod +x "$STUB_DIR/valkey-cli"
}

teardown() {
	teardown_temp_dir
}

acl_calls() {
	grep "ACL SETUSER" "$TEST_TEMP_DIR/bus-calls"
}

@test "every user is made default-deny with its own verbs and patterns: a role reads its mailbox and every findings stream and writes its own three" {
	run_cageworks_container bus-acl acme
	assert_success
	run acl_calls
	assert_line --partial "SETUSER builder on >pw-builder resetkeys resetchannels nocommands +xadd +xread +xrange +xrevrange +xlen +xinfo +ping %R~mailbox:builder %W~control:builder %W~findings:builder %R~findings:* %W~events:builder"
	assert_line --partial "SETUSER reviewer on >pw-reviewer resetkeys resetchannels nocommands"
	assert_line --partial "SETUSER decider on >pw-decider resetkeys resetchannels nocommands +xadd +xread +xrange +xrevrange +xlen +xinfo +ping %R~* %W~commands"
	assert_line --partial "SETUSER executor on >pw-executor resetkeys resetchannels allcommands allkeys allchannels"
	assert_line --partial "SETUSER probes on >pw-probes resetkeys resetchannels nocommands +xadd +ping %W~probes"
}

@test "the default user is turned off last, after every SETUSER" {
	run_cageworks_container bus-acl acme
	assert_success
	run acl_calls
	assert_line --index 5 --partial "SETUSER default off"
	run wc -l <<<"$output"
	assert_output --regexp '^ *6$'
}

@test "a user whose password file is absent is not made" {
	rm "$STATE/bus/reviewer"
	run_cageworks_container bus-acl acme
	assert_success
	run acl_calls
	refute_output --partial "SETUSER reviewer"
	assert_output --partial "SETUSER builder"
}

@test "when the default user is already off, it speaks as the executor with the password in the environment and never on argv" {
	touch "$TEST_TEMP_DIR/default-off"
	run_cageworks_container bus-acl acme
	assert_success
	run grep -c -- "--user executor --no-auth-warning ACL SETUSER" "$TEST_TEMP_DIR/bus-calls"
	assert_output 6
	# The SETUSER lines carry each user's password by nature; what must not
	# appear is the executor's as a --pass argument to speak with.
	run grep -c -- "--pass" "$TEST_TEMP_DIR/bus-calls"
	assert_output 0
	run grep -c "pw-executor" "$TEST_TEMP_DIR/bus-auth"
	assert_output --regexp '^[1-9]'
}

@test "when the default user is off and the executor has no password, it says so and fails" {
	touch "$TEST_TEMP_DIR/default-off"
	rm "$STATE/bus/executor"
	run_cageworks_container bus-acl acme
	assert_failure
	assert_output --partial "executor"
}
