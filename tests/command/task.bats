#!/usr/bin/env bats
# 'nixcage task' files a goal into a factory and reads back what is there.

load ../test_helper/common

setup() {
	setup_temp_dir
	mkdir -p "$TEST_TEMP_DIR/bin"
	export PATH="$TEST_TEMP_DIR/bin:$PATH"
	cat >"$TEST_TEMP_DIR/bin/ssh" <<EOF
#!/usr/bin/env bash
echo "\$@" >>"$TEST_TEMP_DIR/ssh-calls"
EOF
	cat >"$TEST_TEMP_DIR/bin/sudo" <<EOF
#!/usr/bin/env bash
echo "\$@" >>"$TEST_TEMP_DIR/sudo-calls"
EOF
	cat >"$TEST_TEMP_DIR/bin/ps" <<'EOF'
#!/usr/bin/env bash
echo "microvm-run"
EOF
	chmod +x "$TEST_TEMP_DIR/bin/ssh" "$TEST_TEMP_DIR/bin/sudo" "$TEST_TEMP_DIR/bin/ps"
	echo "$$" >"$XDG_STATE_HOME/nixcage/vm.pid"
	write_cache
}

teardown() {
	teardown_temp_dir
}

@test "filing a goal reaches the guest with the factory and role" {
	run_nixcage task file acme builder --acceptance "tests pass"
	[ "$status" -eq 0 ]
	run cat "$TEST_TEMP_DIR/ssh-calls"
	assert_output --partial "nixcage-container task-file acme builder"
}

@test "a goal carries its acceptance criteria, quoted for the remote shell" {
	run_nixcage task file acme builder --acceptance "tests pass and the tracker is clean"
	run cat "$TEST_TEMP_DIR/ssh-calls"
	assert_output --partial "tests\\ pass\\ and\\ the\\ tracker\\ is\\ clean"
}

@test "a goal belongs to a workflow, defaulting until workflows are declared" {
	run_nixcage task file acme builder --acceptance x
	run cat "$TEST_TEMP_DIR/ssh-calls"
	assert_output --partial "task-file acme builder default"
}

@test "a named workflow is carried instead of the default" {
	run_nixcage task file acme builder --workflow ship --acceptance x
	run cat "$TEST_TEMP_DIR/ssh-calls"
	assert_output --partial "task-file acme builder ship"
}

@test "filing without a factory and a role explains itself" {
	run_nixcage task file acme
	assert_failure
	assert_output --partial "task file <factory> <role>"
}

@test "listing a factory's tasks reaches the guest" {
	run_nixcage task list acme
	[ "$status" -eq 0 ]
	run cat "$TEST_TEMP_DIR/ssh-calls"
	assert_output --partial "nixcage-container task-list acme"
}

@test "listing can be narrowed to one state" {
	run_nixcage task list acme ready
	run cat "$TEST_TEMP_DIR/ssh-calls"
	assert_output --partial "task-list acme ready"
}

@test "showing one task reaches the guest" {
	run_nixcage task show acme task-0001
	run cat "$TEST_TEMP_DIR/ssh-calls"
	assert_output --partial "task-show acme task-0001"
}

@test "an unknown task subcommand explains itself rather than guessing" {
	run_nixcage task frobnicate acme
	assert_failure
	assert_output --partial "task"
}

@test "on linux task goes through sudo rather than ssh" {
	export NIXCAGE_OS=linux
	export NIXCAGE_HOST_CONFIG="$TEST_TEMP_DIR/hostconfig"
	echo "WORKSPACE_ROOTS=$TEST_TEMP_DIR/src" >"$NIXCAGE_HOST_CONFIG"
	run_nixcage task list acme
	[ "$status" -eq 0 ]
	run cat "$TEST_TEMP_DIR/sudo-calls"
	assert_output --partial "nixcage-container task-list acme"
	[ ! -f "$TEST_TEMP_DIR/ssh-calls" ]
}
