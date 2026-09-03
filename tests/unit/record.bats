#!/usr/bin/env bats
# The shared record (ADR-013). These drive git-bug for real: a stub would
# only prove we can call ourselves, and every surprise so far came from what
# git-bug actually does.

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/role-uid.sh
	source "$NIXCAGE_ROOT/modules/role-uid.sh"
	# shellcheck source=../../modules/record.sh
	source "$NIXCAGE_ROOT/modules/record.sh"
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
	a="$(nixcage_record_identity "$REPO" builder)"
	b="$(nixcage_record_identity "$REPO" builder)"
	[ -n "$a" ]
	[ "$a" = "$b" ]
}

@test "two roles get two identities" {
	a="$(nixcage_record_identity "$REPO" builder)"
	b="$(nixcage_record_identity "$REPO" architect)"
	[ "$a" != "$b" ]
}

@test "an identity is a full id, since a truncated one fails silently" {
	id="$(nixcage_record_identity "$REPO" builder)"
	[ "${#id}" -eq 64 ]
}

@test "filing an item takes its body from stdin, never an argument" {
	id="$(printf 'ship the change\n\nacceptance: tests pass\n' |
		nixcage_record_new "$REPO" builder)"
	[ -n "$id" ]
	run nixcage_record_show "$REPO" "$id"
	assert_success
	assert_output --partial "ship the change"
}

@test "a comment is attributed to the role that wrote it" {
	id="$(printf 'ship it\n\nbody\n' | nixcage_record_new "$REPO" architect)"
	printf 'builder: picked it up\n' | nixcage_record_comment "$REPO" "$id" builder
	run nixcage_record_show "$REPO" "$id"
	assert_output --partial "builder"
	assert_output --partial "picked it up"
}

@test "two roles writing in turn are attributed separately" {
	id="$(printf 'ship it\n\nbody\n' | nixcage_record_new "$REPO" architect)"
	printf 'from the builder\n' | nixcage_record_comment "$REPO" "$id" builder
	printf 'from the architect\n' | nixcage_record_comment "$REPO" "$id" architect
	run nixcage_record_participants "$REPO" "$id"
	assert_output --partial "builder"
	assert_output --partial "architect"
}

@test "a mention is a label naming a role" {
	run nixcage_record_mention_label architect
	assert_success
	assert_output "needs-architect"
}

@test "a mention label never contains a colon, which breaks the query parser" {
	run nixcage_record_mention_label architect
	refute_output --partial ":"
}

@test "an invalid role cannot become a label" {
	run nixcage_record_mention_label "../evil"
	assert_failure
}

@test "items can be found by who they need, without reading anyone's prose" {
	a="$(printf 'first\n\nbody\n' | nixcage_record_new "$REPO" architect)"
	b="$(printf 'second\n\nbody\n' | nixcage_record_new "$REPO" architect)"
	nixcage_record_mention "$REPO" "$a" architect
	run nixcage_record_needing "$REPO" architect
	assert_success
	assert_output --partial "$a"
	refute_output --partial "$b"
}

@test "nothing needs a role that was never mentioned" {
	printf 'first\n\nbody\n' | nixcage_record_new "$REPO" architect >/dev/null
	run nixcage_record_needing "$REPO" reviewer
	assert_success
	assert_output ""
}

@test "a role's comment files are posted when its turn ends" {
	id="$(printf 'ship it\n\nbody\n' | nixcage_record_new "$REPO" architect)"
	run_dir="$TEST_TEMP_DIR/run"
	mkdir -p "$run_dir/comments"
	printf 'the first thing I found\n' >"$run_dir/comments/1"
	printf 'and the second\n' >"$run_dir/comments/2"
	run nixcage_record_ingest "$REPO" "$run_dir" builder "$id"
	assert_success
	run nixcage_record_show "$REPO" "$id"
	assert_output --partial "the first thing I found"
	assert_output --partial "and the second"
	assert_output --partial "builder"
}

@test "a turn that wrote nothing posts nothing" {
	id="$(printf 'ship it\n\nbody\n' | nixcage_record_new "$REPO" architect)"
	before="$(nixcage_record_show "$REPO" "$id" | grep -c '#')"
	run_dir="$TEST_TEMP_DIR/run"
	mkdir -p "$run_dir/comments"
	run nixcage_record_ingest "$REPO" "$run_dir" builder "$id"
	assert_success
	after="$(nixcage_record_show "$REPO" "$id" | grep -c '#')"
	[ "$before" = "$after" ]
}

@test "the roles a turn asked for become labels" {
	id="$(printf 'ship it\n\nbody\n' | nixcage_record_new "$REPO" architect)"
	run_dir="$TEST_TEMP_DIR/run"
	mkdir -p "$run_dir/comments"
	printf 'architect\nreviewer\n' >"$run_dir/mentions"
	nixcage_record_ingest "$REPO" "$run_dir" builder "$id"
	run nixcage_record_needing "$REPO" architect
	assert_output --partial "$id"
	run nixcage_record_needing "$REPO" reviewer
	assert_output --partial "$id"
}

@test "a role that does not exist cannot be mentioned into being" {
	id="$(printf 'ship it\n\nbody\n' | nixcage_record_new "$REPO" architect)"
	run_dir="$TEST_TEMP_DIR/run"
	mkdir -p "$run_dir/comments"
	printf '../evil\n' >"$run_dir/mentions"
	run nixcage_record_ingest "$REPO" "$run_dir" builder "$id"
	# The bad name is refused; the turn is not failed over it.
	assert_success
	run nixcage_record_show "$REPO" "$id"
	refute_output --partial "evil"
}

@test "the supervisor narrates as itself, not as a role" {
	id="$(printf 'ship it\n\nbody\n' | nixcage_record_new "$REPO" architect)"
	printf 'attempt 1 started\n' | nixcage_record_comment "$REPO" "$id" supervisor
	run nixcage_record_participants "$REPO" "$id"
	assert_output --partial "supervisor"
}
