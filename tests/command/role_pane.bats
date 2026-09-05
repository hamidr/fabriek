#!/usr/bin/env bats
# 'cageworks role --pane' starts a role in its own herdr pane and reports the
# role's lifecycle state, which herdr's own detection cannot do for an agent
# it does not recognise.

load ../test_helper/common

setup() {
	setup_temp_dir
	mkdir -p "$TEST_TEMP_DIR/bin"
	export PATH="$TEST_TEMP_DIR/bin:$PATH"
	# herdr stub: records calls, answers workspace create with a pane id.
	cat >"$TEST_TEMP_DIR/bin/herdr" <<EOF
#!/usr/bin/env bash
echo "\$@" >>"$TEST_TEMP_DIR/herdr-calls"
if [ "\$1" = "workspace" ] && [ "\$2" = "create" ]; then
	echo '{"result":{"root_pane":{"pane_id":"w1:p1"},"workspace":{"workspace_id":"w1"}}}'
fi
EOF
	# nc stub: records what was written to the socket.
	cat >"$TEST_TEMP_DIR/bin/nc" <<EOF
#!/usr/bin/env bash
cat >>"$TEST_TEMP_DIR/socket-writes"
EOF
	chmod +x "$TEST_TEMP_DIR/bin/herdr" "$TEST_TEMP_DIR/bin/nc"
	stub_nixcage
	# A socket that exists so the reporter does not skip itself.
	export CAGEWORKS_HERDR_SOCK="$TEST_TEMP_DIR/herdr.sock"
	python3 -c "
import socket,sys
s=socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(sys.argv[1]); s.listen(1)
" "$CAGEWORKS_HERDR_SOCK"
}

teardown() {
	teardown_temp_dir
}

@test "the pane is a workspace of its own, labelled for the role, and unfocused" {
	run_cageworks role --pane acme builder
	[ "$status" -eq 0 ]
	run cat "$TEST_TEMP_DIR/herdr-calls"
	assert_output --partial "workspace create"
	assert_output --partial "--no-focus"
	assert_output --partial "--label acme/builder"
}

@test "the session runs inside that pane" {
	run_cageworks role --pane acme builder
	run cat "$TEST_TEMP_DIR/herdr-calls"
	assert_output --partial "pane run w1:p1"
	assert_output --partial "role --report-to w1:p1 acme builder"
}

@test "a session command cannot be sent through the pane, since it is typed" {
	run_cageworks role --pane acme builder -- sh -c "echo hi"
	assert_failure
	assert_output --partial "takes no session command"
}

@test "the words sent to the pane are shell-quoted" {
	run_cageworks role --pane acme builder
	run cat "$TEST_TEMP_DIR/herdr-calls"
	refute_output --partial "pane run w1:p1 cageworks role"
	assert_output --partial "role --report-to w1:p1 acme builder"
}

@test "the pane id is printed so anything can watch it" {
	run_cageworks role --pane acme builder
	assert_output --partial "w1:p1"
}

@test "reporting goes to the socket, since the herdr command cannot do it" {
	run_cageworks role --report-to w1:p1 acme builder -- true
	[ "$status" -eq 0 ]
	run cat "$TEST_TEMP_DIR/socket-writes"
	assert_output --partial '"method":"pane.report_agent"'
	assert_output --partial '"pane_id":"w1:p1"'
	assert_output --partial '"agent":"builder"'
	assert_output --partial '"state":"working"'
	assert_output --partial '"state":"idle"'
}

@test "the role is reported working before the session and idle after it" {
	run_cageworks role --report-to w1:p1 acme builder -- true
	run cat "$TEST_TEMP_DIR/socket-writes"
	first="$(grep -o '"state":"[a-z]*"' "$TEST_TEMP_DIR/socket-writes" | head -1)"
	last="$(grep -o '"state":"[a-z]*"' "$TEST_TEMP_DIR/socket-writes" | tail -1)"
	[ "$first" = '"state":"working"' ]
	[ "$last" = '"state":"idle"' ]
}

@test "a session with no reporting writes nothing to the socket" {
	run_cageworks role acme builder -- true
	[ ! -s "$TEST_TEMP_DIR/socket-writes" ] || [ ! -f "$TEST_TEMP_DIR/socket-writes" ]
}

@test "a console that cannot be reached never stops a session" {
	rm -f "$TEST_TEMP_DIR/bin/nc"
	run_cageworks role --report-to w1:p1 acme builder -- true
	[ "$status" -eq 0 ]
	run nixcage_calls
	assert_output --partial "role-enter"
}
