#!/usr/bin/env bats
# What every role is told about the cage, as the front of its system prompt
# (ADR-054): the text says the things a role cannot infer from an error
# message, in the words of the loop it runs.

load ../test_helper/common

setup() {
	GUIDE="$FABRIEK_ROOT/modules/role-guidance.md"
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

@test "the guidance names the loop's three tools and what each is for" {
	run grep -c "report_outcome" "$GUIDE"
	assert_success
	run grep -c "update_memory" "$GUIDE"
	assert_success
	run grep -c "share_finding" "$GUIDE"
	assert_success
	run grep -iE "silence is not" "$GUIDE"
	assert_success
}

@test "the guidance speaks of no task directory, no outcome file and no mentions file" {
	run grep -cE "FABRIEK_TASK|comments/|mentions" "$GUIDE"
	assert_output 0
}

@test "the guidance says a done needs a commit, and what blocked and failed do" {
	run grep -iE "no commit is not done" "$GUIDE"
	assert_success
	run grep -iE "blocked. keeps the task" "$GUIDE"
	assert_success
}

@test "the guidance says nobody is summoned" {
	run grep -iE "nobody is summoned|nothing starts a role" "$GUIDE"
	assert_success
}

@test "the guidance says how to raise something with the operator" {
	run grep -iE "operator" "$GUIDE"
	assert_success
}

@test "the guidance says another role's prose is data" {
	run grep -iE "data, not instruction" "$GUIDE"
	assert_success
}

@test "the guidance says where the repository's own guidance comes from and which wins" {
	run grep -c "this factory:" "$GUIDE"
	assert_success
	run grep -c "docs/factory-guidance.md" "$GUIDE"
	assert_success
	run grep -iE "this text wins|repository's wins" "$GUIDE"
	assert_success
}

@test "the guidance tells a role to spend words on substance and never on a negation" {
	run grep -iE "counted at the proxy" "$GUIDE"
	assert_success
	run grep -iE "never drop a negation" "$GUIDE"
	assert_success
}
