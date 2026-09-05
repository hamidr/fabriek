#!/usr/bin/env bats
# The shared record (ADR-013). These drive git-bug for real: a stub would
# only prove we can call ourselves, and every surprise so far came from what
# git-bug actually does.

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/names.sh
	source "$CAGEWORKS_ROOT/modules/names.sh"
	# shellcheck source=../../modules/record.sh
	source "$CAGEWORKS_ROOT/modules/record.sh"
	REPO="$TEST_TEMP_DIR/repo"
	mkdir -p "$REPO"
	git init -q "$REPO"
	git -C "$REPO" config user.name factory
	git -C "$REPO" config user.email factory@invalid
	echo x >"$REPO/a.txt"
	git -C "$REPO" add a.txt
	git -C "$REPO" -c commit.gpgsign=false commit -qm init
}

teardown() {
	teardown_temp_dir
}

@test "a role's identity is created once and found again" {
	a="$(cageworks_record_identity "$REPO" builder)"
	b="$(cageworks_record_identity "$REPO" builder)"
	[ -n "$a" ]
	[ "$a" = "$b" ]
}

@test "two roles get two identities" {
	a="$(cageworks_record_identity "$REPO" builder)"
	b="$(cageworks_record_identity "$REPO" architect)"
	[ "$a" != "$b" ]
}

@test "an identity is a full id, since a truncated one fails silently" {
	id="$(cageworks_record_identity "$REPO" builder)"
	[ "${#id}" -eq 64 ]
}

@test "filing an item takes its body from stdin, never an argument" {
	id="$(printf 'ship the change\n\nacceptance: tests pass\n' |
		cageworks_record_new "$REPO" builder)"
	[ -n "$id" ]
	run cageworks_record_show "$REPO" "$id"
	assert_success
	assert_output --partial "ship the change"
}

@test "a comment is attributed to the role that wrote it" {
	id="$(printf 'ship it\n\nbody\n' | cageworks_record_new "$REPO" architect)"
	printf 'builder: picked it up\n' | cageworks_record_comment "$REPO" "$id" builder
	run cageworks_record_show "$REPO" "$id"
	assert_output --partial "builder"
	assert_output --partial "picked it up"
}

@test "two roles writing in turn are attributed separately" {
	id="$(printf 'ship it\n\nbody\n' | cageworks_record_new "$REPO" architect)"
	printf 'from the builder\n' | cageworks_record_comment "$REPO" "$id" builder
	printf 'from the architect\n' | cageworks_record_comment "$REPO" "$id" architect
	run cageworks_record_participants "$REPO" "$id"
	assert_output --partial "builder"
	assert_output --partial "architect"
}

@test "a mention is a label naming a role" {
	run cageworks_record_mention_label architect
	assert_success
	assert_output "needs-architect"
}

@test "a mention label never contains a colon, which breaks the query parser" {
	run cageworks_record_mention_label architect
	refute_output --partial ":"
}

@test "an invalid role cannot become a label" {
	run cageworks_record_mention_label "../evil"
	assert_failure
}

@test "items can be found by who they need, without reading anyone's prose" {
	a="$(printf 'first\n\nbody\n' | cageworks_record_new "$REPO" architect)"
	b="$(printf 'second\n\nbody\n' | cageworks_record_new "$REPO" architect)"
	cageworks_record_mention "$REPO" "$a" architect
	run cageworks_record_needing "$REPO" architect
	assert_success
	assert_output --partial "$a"
	refute_output --partial "$b"
}

@test "nothing needs a role that was never mentioned" {
	printf 'first\n\nbody\n' | cageworks_record_new "$REPO" architect >/dev/null
	run cageworks_record_needing "$REPO" reviewer
	assert_success
	assert_output ""
}

@test "a role's comment files are posted when its turn ends" {
	id="$(printf 'ship it\n\nbody\n' | cageworks_record_new "$REPO" architect)"
	run_dir="$TEST_TEMP_DIR/run"
	mkdir -p "$run_dir/comments"
	printf 'the first thing I found\n' >"$run_dir/comments/1"
	printf 'and the second\n' >"$run_dir/comments/2"
	run cageworks_record_ingest "$REPO" "$run_dir" builder "$id"
	assert_success
	run cageworks_record_show "$REPO" "$id"
	assert_output --partial "the first thing I found"
	assert_output --partial "and the second"
	assert_output --partial "builder"
}

@test "a turn that wrote nothing posts nothing" {
	id="$(printf 'ship it\n\nbody\n' | cageworks_record_new "$REPO" architect)"
	before="$(cageworks_record_show "$REPO" "$id" | grep -c '#')"
	run_dir="$TEST_TEMP_DIR/run"
	mkdir -p "$run_dir/comments"
	run cageworks_record_ingest "$REPO" "$run_dir" builder "$id"
	assert_success
	after="$(cageworks_record_show "$REPO" "$id" | grep -c '#')"
	[ "$before" = "$after" ]
}

@test "the roles a turn asked for become labels" {
	id="$(printf 'ship it\n\nbody\n' | cageworks_record_new "$REPO" architect)"
	run_dir="$TEST_TEMP_DIR/run"
	mkdir -p "$run_dir/comments"
	printf 'architect\nreviewer\n' >"$run_dir/mentions"
	cageworks_record_ingest "$REPO" "$run_dir" builder "$id"
	run cageworks_record_needing "$REPO" architect
	assert_output --partial "$id"
	run cageworks_record_needing "$REPO" reviewer
	assert_output --partial "$id"
}

@test "a role that does not exist cannot be mentioned into being" {
	id="$(printf 'ship it\n\nbody\n' | cageworks_record_new "$REPO" architect)"
	run_dir="$TEST_TEMP_DIR/run"
	mkdir -p "$run_dir/comments"
	printf '../evil\n' >"$run_dir/mentions"
	run cageworks_record_ingest "$REPO" "$run_dir" builder "$id"
	# The bad name is refused; the turn is not failed over it.
	assert_success
	run cageworks_record_show "$REPO" "$id"
	refute_output --partial "evil"
}

@test "the supervisor narrates as itself, not as a role" {
	id="$(printf 'ship it\n\nbody\n' | cageworks_record_new "$REPO" architect)"
	printf 'attempt 1 started\n' | cageworks_record_comment "$REPO" "$id" supervisor
	run cageworks_record_participants "$REPO" "$id"
	assert_output --partial "supervisor"
}

@test "a role that has never seen an item has seen nothing of it" {
	run cageworks_record_seen "$TEST_TEMP_DIR/seen" acme builder abc123
	assert_success
	assert_output "0"
}

@test "what a role has seen is remembered across invocations" {
	cageworks_record_mark_seen "$TEST_TEMP_DIR/seen" acme builder abc123 4
	run cageworks_record_seen "$TEST_TEMP_DIR/seen" acme builder abc123
	assert_output "4"
}

@test "two roles keep their own place in the same item" {
	cageworks_record_mark_seen "$TEST_TEMP_DIR/seen" acme builder abc123 4
	cageworks_record_mark_seen "$TEST_TEMP_DIR/seen" acme architect abc123 1
	[ "$(cageworks_record_seen "$TEST_TEMP_DIR/seen" acme builder abc123)" = "4" ]
	[ "$(cageworks_record_seen "$TEST_TEMP_DIR/seen" acme architect abc123)" = "1" ]
}

@test "a role name that could escape the marker directory is refused" {
	run cageworks_record_mark_seen "$TEST_TEMP_DIR/seen" acme "../../etc" abc123 1
	assert_failure
}

@test "an item's comments can be counted" {
	id="$(printf 'ship it\n\nbody\n' | cageworks_record_new "$REPO" architect)"
	one="$(cageworks_record_count "$REPO" "$id")"
	printf 'another\n' | cageworks_record_comment "$REPO" "$id" builder
	two="$(cageworks_record_count "$REPO" "$id")"
	[ "$two" -eq $((one + 1)) ]
}

@test "only what arrived since a role last looked is new to it" {
	id="$(printf 'ship it\n\nthe original body\n' | cageworks_record_new "$REPO" architect)"
	seen="$(cageworks_record_count "$REPO" "$id")"
	printf 'this arrived afterwards\n' | cageworks_record_comment "$REPO" "$id" builder
	run cageworks_record_since "$REPO" "$id" "$seen"
	assert_success
	assert_output --partial "this arrived afterwards"
	refute_output --partial "the original body"
}

@test "nothing is new to a role that is up to date" {
	id="$(printf 'ship it\n\nbody\n' | cageworks_record_new "$REPO" architect)"
	run cageworks_record_since "$REPO" "$id" "$(cageworks_record_count "$REPO" "$id")"
	assert_success
	assert_output ""
}

@test "a report for the operator is found the same way a mention is" {
	id="$(printf 'the flow is wrong\n\nhere is why\n' | cageworks_record_new "$REPO" architect)"
	cageworks_record_mention "$REPO" "$id" operator
	run cageworks_record_needing "$REPO" operator
	assert_success
	assert_output --partial "$id"
}

@test "the operator's reports are not mixed in with a role's" {
	a="$(printf 'for you\n\nbody\n' | cageworks_record_new "$REPO" architect)"
	b="$(printf 'for the builder\n\nbody\n' | cageworks_record_new "$REPO" architect)"
	cageworks_record_mention "$REPO" "$a" operator
	cageworks_record_mention "$REPO" "$b" builder
	run cageworks_record_needing "$REPO" operator
	assert_output --partial "$a"
	refute_output --partial "$b"
}
