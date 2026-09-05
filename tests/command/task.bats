#!/usr/bin/env bats
# 'cageworks task' files a goal into a factory and reads back what is there.
# It reaches the guest program through nixcage's transport and knows nothing
# else about where the cages are.

load ../test_helper/common

setup() {
	setup_temp_dir
	stub_nixcage
}

teardown() {
	teardown_temp_dir
}

@test "filing a goal names the workflow, not a role" {
	run_cageworks task file acme ship --acceptance "tests pass"
	assert_success
	run nixcage_calls
	assert_output --partial "exec -- cageworks-container task-file acme ship"
	# Who does the work is the workflow's first stage, never the caller's pick.
	refute_output --partial "builder"
}

@test "a goal carries its acceptance criteria as one argument" {
	# Every word reaches the guest as argv, so prose with spaces in it is one
	# thing rather than several.
	run_cageworks task file acme ship --acceptance "tests pass and the tracker is clean"
	assert_success
	run nixcage_argv
	assert_line --index 6 "tests pass and the tracker is clean"
}

@test "filing without a factory and a workflow explains itself" {
	run_cageworks task file acme
	assert_failure
	assert_output --partial "task file <factory> <workflow>"
}

@test "an option filing does not understand is refused rather than ignored" {
	run_cageworks task file acme ship --owner builder
	assert_failure
	assert_output --partial "--owner"
}

@test "listing a factory's tasks reaches the guest" {
	run_cageworks task list acme
	assert_success
	run nixcage_calls
	assert_output --partial "cageworks-container task-list acme"
}

@test "listing can be narrowed to one state" {
	run_cageworks task list acme ready
	run nixcage_calls
	assert_output --partial "task-list acme ready"
}

@test "showing one task reaches the guest" {
	run_cageworks task show acme task-0001
	run nixcage_calls
	assert_output --partial "task-show acme task-0001"
}

@test "the thread of a task reaches the guest" {
	run_cageworks task thread acme task-0001
	run nixcage_calls
	assert_output --partial "task-thread acme task-0001"
}

@test "answering a gate carries the answer and its reason" {
	run_cageworks task answer acme task-0001 reject "the tests do not run"
	run nixcage_argv
	assert_line --index 6 "reject"
	assert_line --index 7 "the tests do not run"
}

@test "running a task reaches the guest with the factory and the id" {
	run_cageworks task run acme task-0001
	assert_success
	run nixcage_calls
	assert_output --partial "cageworks-container task-run acme task-0001"
}

@test "running without a task explains itself" {
	run_cageworks task run acme
	assert_failure
	assert_output --partial "task run <factory> <id>"
}

@test "an unknown task subcommand explains itself rather than guessing" {
	run_cageworks task frobnicate acme
	assert_failure
	assert_output --partial "task"
}

@test "no task command asks for a terminal or forwards an agent" {
	# Reading and filing are quick, unattended-safe reads. Only entering a
	# role by hand is a person at a keyboard with keys of their own.
	run_cageworks task list acme
	run_cageworks task run acme task-0001
	run nixcage_calls
	refute_output --partial "--tty"
	refute_output --partial "--agent"
}
