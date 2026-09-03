#!/usr/bin/env bats
# 'nixcage role' enters a declared factory role. Unlike enter it takes no
# project: the repository comes from the declaration inside the VM, and the
# role's worktree lives in nixcage state rather than under a workspace root.

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

@test "role runs the guest role-enter with the factory and role" {
	run_nixcage role acme builder -- true
	[ "$status" -eq 0 ]
	run cat "$TEST_TEMP_DIR/ssh-calls"
	assert_output --partial "nixcage-container role-enter acme builder"
}

@test "role does not need a flake in the current directory" {
	cd "$TEST_TEMP_DIR"
	run_nixcage role acme builder -- true
	[ "$status" -eq 0 ]
	refute_output --partial "flake.nix"
}

@test "role does not require the current directory to be under a workspace root" {
	mkdir -p "$TEST_TEMP_DIR/elsewhere"
	cd "$TEST_TEMP_DIR/elsewhere"
	run_nixcage role acme builder -- true
	[ "$status" -eq 0 ]
	refute_output --partial "workspace root"
}

@test "a session command survives re-splitting by the remote shell" {
	run_nixcage role acme builder -- sh -c "echo one two"
	[ "$status" -eq 0 ]
	run cat "$TEST_TEMP_DIR/ssh-calls"
	assert_output --partial "echo\\ one\\ two"
}

@test "role forwards the agent and lets the VM name its own socket" {
	touch "$TEST_TEMP_DIR/agent.sock"
	export SSH_AUTH_SOCK="$TEST_TEMP_DIR/agent.sock"
	run_nixcage role acme builder -- true
	run cat "$TEST_TEMP_DIR/ssh-calls"
	assert_output --partial "-A"
	assert_output --partial '--auth-sock "$SSH_AUTH_SOCK"'
}

@test "the agent flag precedes the factory, or the guest reads it as the command" {
	touch "$TEST_TEMP_DIR/agent.sock"
	export SSH_AUTH_SOCK="$TEST_TEMP_DIR/agent.sock"
	run_nixcage role acme builder -- true
	run cat "$TEST_TEMP_DIR/ssh-calls"
	assert_output --partial 'role-enter --auth-sock "$SSH_AUTH_SOCK" acme builder'
}

@test "on linux the agent flag also precedes the factory" {
	export NIXCAGE_OS=linux
	export NIXCAGE_HOST_CONFIG="$TEST_TEMP_DIR/hostconfig"
	echo "WORKSPACE_ROOTS=$TEST_TEMP_DIR/src" >"$NIXCAGE_HOST_CONFIG"
	touch "$TEST_TEMP_DIR/agent.sock"
	export SSH_AUTH_SOCK="$TEST_TEMP_DIR/agent.sock"
	run_nixcage role acme builder -- true
	run cat "$TEST_TEMP_DIR/sudo-calls"
	assert_output --partial "role-enter --auth-sock $TEST_TEMP_DIR/agent.sock acme builder"
}

@test "role without a factory and a role explains itself" {
	run_nixcage role acme
	assert_failure
	assert_output --partial "role <factory> <role>"
}

@test "the guest forwards every option it is given, not just the agent socket" {
	# role-enter parses options before the positionals; anything it fails to
	# recognise is read as the factory name, which fails far from the cause.
	run grep -n -- "--auth-sock | --task-dir | --signing-key" "$NIXCAGE_ROOT/modules/container.nix"
	assert_success
}

@test "an unattended run signs with a role key and forwards no agent" {
	# The supervisor's own path must never pass --auth-sock: a run nobody is
	# watching holding the operator's agent is the thing ADR-009 removes.
	run grep -n -A3 'timeout "\$limit" "\$0" role-enter' "$NIXCAGE_ROOT/modules/container.nix"
	assert_success
	assert_output --partial "--signing-key"
	refute_output --partial "--auth-sock"
}

@test "on linux role goes through sudo rather than ssh" {
	export NIXCAGE_OS=linux
	export NIXCAGE_HOST_CONFIG="$TEST_TEMP_DIR/hostconfig"
	echo "WORKSPACE_ROOTS=$TEST_TEMP_DIR/src" >"$NIXCAGE_HOST_CONFIG"
	run_nixcage role acme builder -- true
	[ "$status" -eq 0 ]
	run cat "$TEST_TEMP_DIR/sudo-calls"
	assert_output --partial "nixcage-container role-enter acme builder"
	[ ! -f "$TEST_TEMP_DIR/ssh-calls" ]
}

@test "a role worktree is reachable at the path git recorded, not only /workspace" {
	# nix resolves a flake through libgit2, which opens a linked worktree by
	# the absolute path stored beside it; bound at /workspace alone, every
	# flake command in a role session fails on a missing directory.
	run grep -n -- '--bind=\$project:\$project' "$NIXCAGE_ROOT/modules/container.nix"
	assert_success
}
