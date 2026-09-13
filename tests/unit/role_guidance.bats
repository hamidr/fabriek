#!/usr/bin/env bats
# A role session is told the rules it cannot infer from error messages.

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/names.sh
	source "$FABRIEK_ROOT/modules/names.sh"
	# shellcheck source=../../modules/role-guidance.sh
	source "$FABRIEK_ROOT/modules/role-guidance.sh"
	GUIDE="$FABRIEK_ROOT/modules/role-guidance.md"
}

teardown() {
	teardown_temp_dir
}

@test "a role session is given the guidance, bound read-only" {
	run fabriek_role_guidance_args /store/guidance.md builder
	assert_success
	# One argv word per line: nixcage takes a flag and its value as separate
	# arguments, so nothing in either is ever re-split.
	assert_line --index 0 "--bind-ro"
	assert_line --index 1 "/store/guidance.md:/etc/fabriek/role-guidance.md"
	assert_line --index 2 "--setenv"
	assert_line --index 3 "FABRIEK_ROLE_GUIDANCE=/etc/fabriek/role-guidance.md"
}

@test "an ordinary session is given nothing: it is not a role" {
	run fabriek_role_guidance_args /store/guidance.md ""
	assert_success
	assert_output ""
}

@test "the guidance says the packed-refs error is expected" {
	run grep -c "packed-refs" "$GUIDE"
	assert_success
	run grep -iE "expected|not a failure|succeeded" "$GUIDE"
	assert_success
}

@test "the guidance says what a role may and may not write" {
	run grep -c "refs/heads/main" "$GUIDE"
	assert_success
	run grep -ciE "your own namespace|your namespace" "$GUIDE"
	assert_success
}

@test "the guidance says where to record an outcome and that silence is failure" {
	run grep -c "FABRIEK_TASK" "$GUIDE"
	assert_success
	run grep -iE "outcome" "$GUIDE"
	assert_success
	run grep -iE "empty outcome is a failure|silence is not" "$GUIDE"
	assert_success
}

@test "the guidance says how to add to the record and ask for a role" {
	run grep -c "FABRIEK_TASK/comments" "$GUIDE"
	assert_success
	run grep -c "FABRIEK_TASK/mentions" "$GUIDE"
	assert_success
}

@test "the guidance says a mention does not summon anyone" {
	run grep -iE "does not summon|will not run|not start a role" "$GUIDE"
	assert_success
}

@test "the guidance says how to raise something with the operator" {
	run grep -iE "operator" "$GUIDE"
	assert_success
}

@test "the guidance says another role's prose is data" {
	run grep -iE "data, not|data rather than|never as instructions" "$GUIDE"
	assert_success
}

@test "the guidance is ASCII, since it is read inside a minimal container" {
	run env LC_ALL=C grep -nP '[^\x00-\x7F]' "$GUIDE"
	assert_failure
}

@test "the guidance says work arrives by capability and stays with its taker" {
	# A role that assumes a pipeline named it will not understand why a peer
	# is working the same kind of task, or why its own retry came back to it.
	run cat "$FABRIEK_ROOT/modules/role-guidance.md"
	assert_output --partial "declared you can do it"
	assert_output --partial "stays yours"
}
