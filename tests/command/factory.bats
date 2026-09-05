#!/usr/bin/env bats
# 'cageworks factory' is the factory as a whole: what it is doing, handing its
# work to the operator, and starting it again after it stopped itself.

load ../test_helper/common

setup() {
	setup_temp_dir
	stub_nixcage
}

teardown() {
	teardown_temp_dir
}

@test "the read-only verbs reach the guest with only the factory named" {
	for sub in status sync resume reports; do
		rm -f "$NIXCAGE_CALLS"
		run_cageworks factory "$sub" acme
		assert_success
		run nixcage_calls
		assert_output --partial "cageworks-container factory-$sub acme"
	done
}

@test "integrating names the commit as well" {
	run_cageworks factory integrate acme abc1234
	assert_success
	run nixcage_calls
	assert_output --partial "cageworks-container factory-integrate acme abc1234"
}

@test "integrating without a commit explains itself rather than guessing one" {
	# Which commit to advance to is the reviewer's judgement. Defaulting to
	# anything would make the supervisor choose it.
	run_cageworks factory integrate acme
	assert_failure
	assert_output --partial "factory integrate <factory> <commit>"
}

@test "a verb without a factory explains itself" {
	run_cageworks factory status
	assert_failure
	assert_output --partial "factory status|sync|resume|reports"
}

@test "an unknown verb explains itself rather than being passed through" {
	# Anything reaching the guest as a verb becomes part of a command line
	# there, so the refusal belongs here.
	run_cageworks factory frobnicate acme
	assert_failure
	assert_output --partial "factory status|sync|integrate|resume|reports"
	[ ! -f "$NIXCAGE_CALLS" ]
}
