#!/usr/bin/env bats
# 'cageworks role' enters a declared role by hand. Unlike entering a project it
# takes no directory: the repository comes from the declaration and the role's
# worktree lives in nixcage state, so nothing about it depends on where it is
# typed.

load ../test_helper/common

setup() {
	setup_temp_dir
	stub_nixcage
}

teardown() {
	teardown_temp_dir
}

@test "role runs the guest role-enter with the factory and the role" {
	run_cageworks role acme builder -- true
	assert_success
	run nixcage_calls
	assert_output --partial "cageworks-container role-enter acme builder true"
}

@test "role needs no flake in the current directory and no workspace root" {
	# A role works a worktree the supervisor keeps, not a project the operator
	# is standing in.
	cd "$TEST_TEMP_DIR"
	run_cageworks role acme builder -- true
	assert_success
	refute_output --partial "flake.nix"
	refute_output --partial "workspace root"
}

@test "a session command reaches the guest as the words it was written as" {
	run_cageworks role acme builder -- sh -c "echo one two"
	assert_success
	run nixcage_argv
	assert_line --index 4 "sh"
	assert_line --index 5 "-c"
	assert_line --index 6 "echo one two"
}

@test "a person entering a role forwards their agent" {
	# This is a person, not the supervisor dispatching: they sign through
	# their own agent exactly as entering an ordinary project does, and the
	# cage key of ADR-009 belongs to the run nobody watches.
	touch "$TEST_TEMP_DIR/agent.sock"
	export SSH_AUTH_SOCK="$TEST_TEMP_DIR/agent.sock"
	run_cageworks role acme builder -- true
	assert_success
	run nixcage_calls
	assert_output --partial "cageworks-container role-enter --agent acme builder"
	## And the transport forwards the operator's own agent, which is a
	## different thing from the flag the guest program reads: one says which
	## socket to sign through, the other carries it across the connection.
	run ssh_flags
	assert_output --partial " -A"
}

@test "the socket is never named on this side, because it is not ours to name" {
	# On macOS the agent socket lives in the VM. A path spelt here would be
	# the operator's own and would resolve to nothing over there.
	touch "$TEST_TEMP_DIR/agent.sock"
	export SSH_AUTH_SOCK="$TEST_TEMP_DIR/agent.sock"
	run_cageworks role acme builder -- true
	run nixcage_calls
	refute_output --partial "$TEST_TEMP_DIR/agent.sock"
	refute_output --partial "--auth-sock"
}

@test "with no agent to forward the session still starts" {
	unset SSH_AUTH_SOCK
	run_cageworks role acme builder -- true
	assert_success
	run nixcage_calls
	refute_output --partial "--agent"
}

@test "the agent flag precedes the factory, or the guest reads it as the command" {
	touch "$TEST_TEMP_DIR/agent.sock"
	export SSH_AUTH_SOCK="$TEST_TEMP_DIR/agent.sock"
	run_cageworks role acme builder -- true
	run nixcage_argv
	assert_line --index 2 "--agent"
	assert_line --index 3 "acme"
}

@test "an interactive session asks for a terminal and a commanded one does not" {
	# A terminal is the transport's to ask for now: ssh -t rather than a flag
	# the guest program reads, so it is asserted where it is actually passed.
	run_cageworks role acme builder
	run ssh_flags
	assert_output --partial " -t"
	rm -f "$SSH_FLAGS"
	run_cageworks role acme builder -- true
	run ssh_flags
	refute_output --partial " -t"
}

@test "role without a factory and a role explains itself" {
	run_cageworks role acme
	assert_failure
	assert_output --partial "role [--pane] <factory> <role>"
}

# ADR-032. The machine clones the repository's own remote, so what reaches the
# guest is a URL both sides can fetch and never a path that means something
# only on this host. A factory's machine cannot open /Users/somebody/src/acme.
@test "the repository named to the guest is an origin, not a path on this host" {
	local repo="$TEST_TEMP_DIR/checkout"
	git init -q "$repo"
	git -C "$repo" remote add origin https://example.invalid/acme.git
	cat >"$CAGEWORKS_CONFIG" <<EOF
[caps]
memory = "16G"
cores = 8

[factories.acme]
path = "$repo"
EOF
	run_cageworks role acme builder -- true
	assert_success

	run nixcage_argv
	assert_line "https://example.invalid/acme.git"
	refute_line "$repo"
}
