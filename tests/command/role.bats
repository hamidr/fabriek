#!/usr/bin/env bats
# 'fabriek enter' enters a declared role by hand. Unlike entering a project it
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

@test "enter runs the machine role-enter with the factory and the role" {
	run_fabriek -f acme enter builder -- true
	assert_success
	run nixcage_calls
	assert_output --partial "fabriek-container role-enter acme builder true"
}

@test "enter needs no flake in the current directory and no workspace root" {
	# A role works a worktree the supervisor keeps, not a project the operator
	# is standing in.
	cd "$TEST_TEMP_DIR"
	run_fabriek -f acme enter builder -- true
	assert_success
	refute_output --partial "flake.nix"
	refute_output --partial "workspace root"
}

@test "a session command reaches the machine as the words it was written as" {
	run_fabriek -f acme enter builder -- sh -c "echo one two"
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
	run_fabriek -f acme enter builder -- true
	assert_success
	run nixcage_calls
	assert_output --partial "fabriek-container role-enter --agent acme builder"
	## And the transport forwards the operator's own agent, which is a
	## different thing from the flag the machine program reads: one says which
	## socket to sign through, the other carries it across the connection.
	run ssh_flags
	assert_output --partial " -A"
}

@test "the socket is never named on this side, because it is not ours to name" {
	# On macOS the agent socket lives in the VM. A path spelt here would be
	# the operator's own and would resolve to nothing over there.
	touch "$TEST_TEMP_DIR/agent.sock"
	export SSH_AUTH_SOCK="$TEST_TEMP_DIR/agent.sock"
	run_fabriek -f acme enter builder -- true
	run nixcage_calls
	refute_output --partial "$TEST_TEMP_DIR/agent.sock"
	refute_output --partial "--auth-sock"
}

@test "with no agent to forward the session still starts" {
	unset SSH_AUTH_SOCK
	run_fabriek -f acme enter builder -- true
	assert_success
	run nixcage_calls
	refute_output --partial "--agent"
}

@test "the agent flag precedes the factory, or the machine reads it as the command" {
	touch "$TEST_TEMP_DIR/agent.sock"
	export SSH_AUTH_SOCK="$TEST_TEMP_DIR/agent.sock"
	run_fabriek -f acme enter builder -- true
	run nixcage_argv
	assert_line --index 2 "--agent"
	assert_line --index 3 "acme"
}

@test "an interactive session asks for a terminal and a commanded one does not" {
	# A terminal is the transport's to ask for now: ssh -t rather than a flag
	# the machine program reads, so it is asserted where it is actually passed.
	run_fabriek -f acme enter builder
	run ssh_flags
	assert_output --partial " -t"
	rm -f "$SSH_FLAGS"
	run_fabriek -f acme enter builder -- true
	run ssh_flags
	refute_output --partial " -t"
}

@test "enter without a role explains itself, on stderr, with a usage exit" {
	run_fabriek -f acme enter
	[ "$status" -eq 2 ]
	assert_output --partial "enter ROLE"
}

# ADR-032. The machine clones the repository's own remote, so what reaches the
# machine is a URL both sides can fetch and never a path that means something
# only on this host. A factory's machine cannot open /Users/somebody/src/acme.
@test "the repository named to the machine is an origin, not a path on this host" {
	local repo="$TEST_TEMP_DIR/checkout"
	git init -q "$repo"
	git -C "$repo" remote add origin https://example.invalid/acme.git
	cat >"$FABRIEK_CONFIG" <<EOF
[caps]
memory = "16G"
cores = 8

[factories.acme]
path = "$repo"
EOF
	run_fabriek -f acme enter builder -- true
	assert_success

	run nixcage_argv
	assert_line "https://example.invalid/acme.git"
	refute_line "$repo"
}

# A role's transcript is the session pi kept in its home on the machine; the
# host asks the machine program and prints what it prints (task 6).
@test "log asks the machine for the role's sessions, and for one session as text when asked" {
	run_fabriek -f acme log builder
	assert_success
	run nixcage_calls
	assert_output --partial "fabriek-container role-transcript acme builder"
	run_fabriek -f acme log -t builder 2026-09-14T10-00-00-aaaa.jsonl
	assert_success
	run nixcage_calls
	assert_output --partial "fabriek-container role-transcript acme builder 2026-09-14T10-00-00-aaaa.jsonl --text"
}

@test "stop -k reaches the machine with the flag after the factory and the role" {
	run_fabriek -f acme stop -k builder
	assert_success
	run nixcage_calls
	assert_output --partial "fabriek-container role-stop acme builder --now"
}

# The factory is an option, given once, before or after the verb (ADR-047).
@test "the factory option is taken before or after the verb, and from the environment" {
	run_fabriek enter -f acme builder -- true
	assert_success
	export FABRIEK_FACTORY=acme
	run_fabriek enter builder -- true
	unset FABRIEK_FACTORY
	assert_success
	run nixcage_calls
	assert_line --index 1 --partial "fabriek-container role-enter acme builder true"
}

@test "with one factory registered, the factory need not be named; with two, the choice is asked for" {
	local repo="$TEST_TEMP_DIR/checkout"
	git init -q "$repo"
	git -C "$repo" remote add origin https://example.invalid/acme.git
	printf '[factories.acme]\npath = "%s"\n' "$repo" >"$FABRIEK_CONFIG"
	run_fabriek enter builder -- true
	assert_success
	printf '[factories.widgets]\npath = "%s"\n' "$repo" >>"$FABRIEK_CONFIG"
	run_fabriek enter builder -- true
	assert_failure
	[ "$status" -eq 2 ]
	assert_output --partial "fabriek: which factory"
	assert_output --partial "acme"
	assert_output --partial "widgets"
}

@test "a verb's usage is one line on stderr with exit 2, and -h prints it with exit 0" {
	run_fabriek -f acme stop
	[ "$status" -eq 2 ]
	assert_line --index 0 --partial "usage: fabriek"
	assert_line --index 0 --partial "stop [-k] ROLE"
	run_fabriek stop -h
	assert_success
	assert_output --partial "stop [-k] ROLE"
}
