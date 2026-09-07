#!/usr/bin/env bats
# The shared record (ADR-022, ADR-024). These drive git-bug for real: a stub
# would only prove we can call ourselves, and every surprise so far came from
# what git-bug actually does.

bats_require_minimum_version 1.5.0

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

# Holding the record's lock, the way a peer holds it (ADR-024). git-bug 0.10.1
# writes the holder's pid with no trailing newline and breaks a lock whose pid
# is gone, both measured before these were written.
hold_the_record() {
	sleep 30 &
	LOCK_HOLDER=$!
	mkdir -p "$REPO/.git/git-bug"
	printf '%s' "$LOCK_HOLDER" >"$REPO/.git/git-bug/lock"
}

# run() loses a sourced function's stderr unless something folds it in, and a
# pipeline into one loses the function itself.
needing_with_stderr() {
	cageworks_record_needing "$REPO" "$1" 2>&1
}

comment_from_stdin() {
	printf 'the outcome of a turn\n' | cageworks_record_comment "$REPO" "$1" builder
}

# grep -c exits non-zero when it counts nothing, and nothing is a legitimate
# answer here.
count_lines() {
	grep -c . || true
}

release_the_record() {
	kill "$LOCK_HOLDER" 2>/dev/null || true
	rm -f "$REPO/.git/git-bug/lock"
}

@test "a reader that cannot take the lock fails rather than reporting an empty queue" {
	export CAGEWORKS_RECORD_ATTEMPTS=3
	cageworks_record_mention "$REPO" "$(printf 'x\n\ny\n' | cageworks_record_new "$REPO" builder)" builder
	hold_the_record
	run --separate-stderr cageworks_record_needing "$REPO" builder
	release_the_record
	[ "$status" -ne 0 ]
	# Nothing on stdout. A caller that read this as the queue would read a
	# locked record as a record with no work in it.
	[ -z "$stdout" ]
}

@test "a lock failure says so, since a silent one reads as no work" {
	export CAGEWORKS_RECORD_ATTEMPTS=2
	hold_the_record
	run needing_with_stderr builder
	release_the_record
	[ "$status" -ne 0 ]
	[[ "$output" == *"locked"* ]]
}

@test "a call waits out a lock that clears and then lands" {
	export CAGEWORKS_RECORD_ATTEMPTS=60
	item="$(printf 'held\n\nbody\n' | cageworks_record_new "$REPO" builder)"
	hold_the_record
	( sleep 1; release_the_record ) &
	run cageworks_record_mention "$REPO" "$item" builder
	wait
	[ "$status" -eq 0 ]
	cageworks_record_needing "$REPO" builder | grep -q "$item"
}

@test "a body survives a retry, because a retried command replays its input" {
	export CAGEWORKS_RECORD_ATTEMPTS=60
	item="$(printf 'held\n\nbody\n' | cageworks_record_new "$REPO" builder)"
	hold_the_record
	( sleep 1; release_the_record ) &
	run comment_from_stdin "$item"
	wait
	[ "$status" -eq 0 ]
	cageworks_record_show "$REPO" "$item" | grep -q "the outcome of a turn"
}

@test "concurrent writers all land, which bare git-bug does not manage" {
	items=()
	for n in 1 2 3 4; do
		items+=("$(printf 'item %s\n\nbody\n' "$n" | cageworks_record_new "$REPO" builder)")
	done

	# Separate processes, which is what agents are. Forking bats itself gives
	# each writer a copy of the harness's job control and file descriptors,
	# and what that measures is bats.
	cat >"$TEST_TEMP_DIR/mention" <<-SH
		#!/usr/bin/env bash
		source "$CAGEWORKS_ROOT/modules/names.sh"
		source "$CAGEWORKS_ROOT/modules/record.sh"
		cageworks_record_mention "$REPO" "\$1" builder
	SH
	chmod +x "$TEST_TEMP_DIR/mention"

	for item in "${items[@]}"; do
		CAGEWORKS_RECORD_ATTEMPTS=120 "$TEST_TEMP_DIR/mention" "$item" </dev/null &
	done
	wait

	found="$(cageworks_record_needing "$REPO" builder | count_lines)"
	[ "$found" -eq 4 ]
}

@test "the wrapper gives up rather than retrying a held lock forever" {
	export CAGEWORKS_RECORD_ATTEMPTS=2
	hold_the_record
	before="$SECONDS"
	run cageworks_record_needing "$REPO" builder
	elapsed=$((SECONDS - before))
	release_the_record
	[ "$status" -ne 0 ]
	[ "$elapsed" -lt 10 ]
}

@test "counting a locked record fails rather than reporting no comments" {
	export CAGEWORKS_RECORD_ATTEMPTS=2
	item="$(printf 'counted\n\nbody\n' | cageworks_record_new "$REPO" builder)"
	printf 'a comment\n' | cageworks_record_comment "$REPO" "$item" builder
	hold_the_record
	run --separate-stderr cageworks_record_count "$REPO" "$item"
	release_the_record
	[ "$status" -ne 0 ]
	# Zero is a number a caller acts on, so a failed read must not produce one.
	[ "$stdout" != "0" ]
}

@test "what is new to a role is not everything again when the record is locked" {
	export CAGEWORKS_RECORD_ATTEMPTS=2
	item="$(printf 'seen\n\nbody\n' | cageworks_record_new "$REPO" builder)"
	hold_the_record
	run --separate-stderr cageworks_record_since "$REPO" "$item" 0
	release_the_record
	[ "$status" -ne 0 ]
	[ -z "$stdout" ]
}

@test "an attempt that stops answering is killed and the next one is tried" {
	# git-bug has been seen still running forty-five minutes into a concurrent
	# label write. A retry loop cannot help with that on its own, so this is
	# the bound rather than the retry: the stub is ours, because what is under
	# test is what we do about a wedged call, not what wedges it.
	stub="$TEST_TEMP_DIR/bin"
	mkdir -p "$stub"
	cat >"$stub/git-bug" <<-SH
		#!/usr/bin/env bash
		echo call >>"$TEST_TEMP_DIR/calls"
		if [ "\$(grep -c . "$TEST_TEMP_DIR/calls")" -eq 1 ]; then
			# exec, so the deadline reaches sleep itself. A bash that is
			# waiting on a foreground child defers the signal until the child
			# returns, which turns a five-second bound into a ten-second one
			# and makes what the wrapper sees depend on the machine's load.
			exec sleep 60
		fi
		exit 0
	SH
	chmod +x "$stub/git-bug"
	PATH="$stub:$PATH"

	# The bound has to clear process startup on a loaded machine, or the stub
	# is killed before it records the attempt and the test measures the load.
	export CAGEWORKS_RECORD_TIMEOUT=5 CAGEWORKS_RECORD_ATTEMPTS=6
	run cageworks_git_bug "$REPO" bug show anything
	[ "$status" -eq 0 ]
	[ "$(grep -c . "$TEST_TEMP_DIR/calls")" -ge 2 ]
}

@test "a call that never answers gives up rather than holding a turn open" {
	stub="$TEST_TEMP_DIR/bin"
	mkdir -p "$stub"
	cat >"$stub/git-bug" <<-SH
		#!/usr/bin/env bash
		exec sleep 60
	SH
	chmod +x "$stub/git-bug"
	PATH="$stub:$PATH"

	export CAGEWORKS_RECORD_TIMEOUT=2 CAGEWORKS_RECORD_ATTEMPTS=2
	before="$SECONDS"
	run cageworks_git_bug "$REPO" bug show anything
	elapsed=$((SECONDS - before))
	[ "$status" -ne 0 ]
	[ "$elapsed" -lt 30 ]
}
