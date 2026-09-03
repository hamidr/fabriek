#!/usr/bin/env bats
# The store a factory's tasks live in (PRD-003 phase 2). Durable, safe under
# concurrent writers, and ordered oldest-first because there is no priority.

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/role-uid.sh
	source "$NIXCAGE_ROOT/modules/role-uid.sh"
	# shellcheck source=../../modules/task-store.sh
	source "$NIXCAGE_ROOT/modules/task-store.sh"
	ROOT="$TEST_TEMP_DIR/tasks"
}

teardown() {
	teardown_temp_dir
}

@test "a filed task starts proposed, since nothing has checked it yet" {
	id="$(nixcage_task_new "$ROOT" acme ship builder)"
	run nixcage_task_get "$ROOT" acme "$id" state
	assert_success
	assert_output "proposed"
}

@test "a task remembers who owns it and which workflow it belongs to" {
	id="$(nixcage_task_new "$ROOT" acme ship builder)"
	[ "$(nixcage_task_get "$ROOT" acme "$id" role)" = "builder" ]
	[ "$(nixcage_task_get "$ROOT" acme "$id" workflow)" = "ship" ]
}

@test "task ids are distinct and never reissued" {
	a="$(nixcage_task_new "$ROOT" acme ship builder)"
	b="$(nixcage_task_new "$ROOT" acme ship builder)"
	[ "$a" != "$b" ]
	rm -rf "${ROOT:?}/acme/$a"
	c="$(nixcage_task_new "$ROOT" acme ship builder)"
	[ "$c" != "$a" ]
}

@test "a task survives being written and read back later" {
	id="$(nixcage_task_new "$ROOT" acme ship builder)"
	nixcage_task_set "$ROOT" acme "$id" acceptance "tests pass"
	[ "$(nixcage_task_get "$ROOT" acme "$id" acceptance)" = "tests pass" ]
}

@test "a body long enough to hold a diff survives intact" {
	id="$(nixcage_task_new "$ROOT" acme ship builder)"
	body="$(printf 'line %s\n' $(seq 1 500))"
	nixcage_task_set "$ROOT" acme "$id" body "$body"
	[ "$(nixcage_task_get "$ROOT" acme "$id" body)" = "$body" ]
}

@test "a value with awkward bytes round-trips unchanged" {
	id="$(nixcage_task_new "$ROOT" acme ship builder)"
	awkward='a b	c "quoted" $VAR * ; rm -rf / \backslash'
	nixcage_task_set "$ROOT" acme "$id" acceptance "$awkward"
	[ "$(nixcage_task_get "$ROOT" acme "$id" acceptance)" = "$awkward" ]
}

@test "an unset field reads empty rather than failing" {
	id="$(nixcage_task_new "$ROOT" acme ship builder)"
	run nixcage_task_get "$ROOT" acme "$id" outcome
	assert_success
	assert_output ""
}

@test "a task that does not exist is refused rather than invented" {
	run nixcage_task_get "$ROOT" acme task-9999 state
	assert_failure
}

@test "tasks list oldest first, because ordering is FIFO" {
	a="$(nixcage_task_new "$ROOT" acme ship builder)"
	b="$(nixcage_task_new "$ROOT" acme ship builder)"
	c="$(nixcage_task_new "$ROOT" acme ship builder)"
	run nixcage_task_list "$ROOT" acme
	assert_line --index 0 "$a"
	assert_line --index 1 "$b"
	assert_line --index 2 "$c"
}

@test "listing can be narrowed to one state" {
	a="$(nixcage_task_new "$ROOT" acme ship builder)"
	b="$(nixcage_task_new "$ROOT" acme ship builder)"
	nixcage_task_set "$ROOT" acme "$b" state ready
	run nixcage_task_list "$ROOT" acme ready
	assert_output "$b"
	refute_output --partial "$a"
}

@test "a field name that could escape the task directory is refused" {
	id="$(nixcage_task_new "$ROOT" acme ship builder)"
	run nixcage_task_set "$ROOT" acme "$id" "../../escape" x
	assert_failure
	run nixcage_task_get "$ROOT" acme "$id" "../../escape"
	assert_failure
}

@test "a state outside the declared set is refused" {
	id="$(nixcage_task_new "$ROOT" acme ship builder)"
	run nixcage_task_set "$ROOT" acme "$id" state "nearly-done"
	assert_failure
	assert_output --partial "state"
}

@test "every declared task state is accepted" {
	id="$(nixcage_task_new "$ROOT" acme ship builder)"
	for st in proposed ready running blocked awaiting-review done failed cancelled; do
		nixcage_task_set "$ROOT" acme "$id" state "$st" || return 1
		[ "$(nixcage_task_get "$ROOT" acme "$id" state)" = "$st" ] || return 1
	done
}

@test "concurrent filing never hands out the same id" {
	for _ in 1 2 3 4 5 6 7 8; do
		nixcage_task_new "$ROOT" acme ship builder >>"$TEST_TEMP_DIR/ids" &
	done
	wait
	total="$(wc -l <"$TEST_TEMP_DIR/ids" | tr -d ' ')"
	distinct="$(sort -u "$TEST_TEMP_DIR/ids" | wc -l | tr -d ' ')"
	[ "$total" = "8" ]
	[ "$distinct" = "8" ]
}

@test "a task with everything its workflow requires becomes ready" {
	id="$(nixcage_task_new "$ROOT" acme ship builder)"
	nixcage_task_set "$ROOT" acme "$id" acceptance "tests pass"
	run nixcage_task_ready "$ROOT" acme "$id" role acceptance
	assert_success
	[ "$(nixcage_task_get "$ROOT" acme "$id" state)" = "ready" ]
}

@test "a task with no stated finish line stays proposed and says which field" {
	id="$(nixcage_task_new "$ROOT" acme ship builder)"
	run nixcage_task_ready "$ROOT" acme "$id" role acceptance
	assert_failure
	assert_output --partial "acceptance"
	[ "$(nixcage_task_get "$ROOT" acme "$id" state)" = "proposed" ]
}

@test "a field present but empty does not count as present" {
	id="$(nixcage_task_new "$ROOT" acme ship builder)"
	nixcage_task_set "$ROOT" acme "$id" acceptance ""
	run nixcage_task_ready "$ROOT" acme "$id" role acceptance
	assert_failure
}

@test "readiness is checked, never judged" {
	id="$(nixcage_task_new "$ROOT" acme ship builder)"
	nixcage_task_set "$ROOT" acme "$id" acceptance "x"
	run nixcage_task_ready "$ROOT" acme "$id" role acceptance
	assert_success
}

@test "a task already past proposed is not dragged back to ready" {
	id="$(nixcage_task_new "$ROOT" acme ship builder)"
	nixcage_task_set "$ROOT" acme "$id" acceptance "tests pass"
	nixcage_task_set "$ROOT" acme "$id" state done
	run nixcage_task_ready "$ROOT" acme "$id" role acceptance
	assert_failure
	[ "$(nixcage_task_get "$ROOT" acme "$id" state)" = "done" ]
}

@test "attempting a ready task makes it running and counts the attempt" {
	id="$(nixcage_task_new "$ROOT" acme ship builder)"
	nixcage_task_set "$ROOT" acme "$id" state ready
	run nixcage_task_attempt "$ROOT" acme "$id" 2
	assert_success
	[ "$(nixcage_task_get "$ROOT" acme "$id" state)" = "running" ]
	[ "$(nixcage_task_get "$ROOT" acme "$id" attempts)" = "1" ]
}

@test "a task that is not ready cannot be attempted" {
	id="$(nixcage_task_new "$ROOT" acme ship builder)"
	run nixcage_task_attempt "$ROOT" acme "$id" 2
	assert_failure
	[ "$(nixcage_task_get "$ROOT" acme "$id" state)" = "proposed" ]
}

@test "settling records the outcome and hands the work on" {
	id="$(nixcage_task_new "$ROOT" acme ship builder)"
	nixcage_task_set "$ROOT" acme "$id" state ready
	nixcage_task_attempt "$ROOT" acme "$id" 2
	run nixcage_task_settle "$ROOT" acme "$id" "branch pushed, tests green"
	assert_success
	[ "$(nixcage_task_get "$ROOT" acme "$id" state)" = "awaiting-review" ]
	[ "$(nixcage_task_get "$ROOT" acme "$id" outcome)" = "branch pushed, tests green" ]
}

@test "settling with nothing recorded is a failure, since silence is not success" {
	id="$(nixcage_task_new "$ROOT" acme ship builder)"
	nixcage_task_set "$ROOT" acme "$id" state ready
	nixcage_task_attempt "$ROOT" acme "$id" 2
	run nixcage_task_settle "$ROOT" acme "$id" ""
	assert_failure
	[ "$(nixcage_task_get "$ROOT" acme "$id" state)" != "awaiting-review" ]
}

@test "a failed attempt returns the task to ready and records why" {
	id="$(nixcage_task_new "$ROOT" acme ship builder)"
	nixcage_task_set "$ROOT" acme "$id" state ready
	nixcage_task_attempt "$ROOT" acme "$id" 3
	run nixcage_task_failed "$ROOT" acme "$id" "the session crashed" 3
	assert_success
	[ "$(nixcage_task_get "$ROOT" acme "$id" state)" = "ready" ]
	[ "$(nixcage_task_get "$ROOT" acme "$id" failure)" = "the session crashed" ]
}

@test "a task that exhausts its attempts stops rather than consuming a budget" {
	id="$(nixcage_task_new "$ROOT" acme ship builder)"
	nixcage_task_set "$ROOT" acme "$id" state ready
	nixcage_task_attempt "$ROOT" acme "$id" 2
	nixcage_task_failed "$ROOT" acme "$id" "first" 2
	nixcage_task_attempt "$ROOT" acme "$id" 2
	nixcage_task_failed "$ROOT" acme "$id" "second" 2
	[ "$(nixcage_task_get "$ROOT" acme "$id" state)" = "failed" ]
	run nixcage_task_attempt "$ROOT" acme "$id" 2
	assert_failure
}

@test "a run that outlives its limit is a failed attempt, not a lost task" {
	id="$(nixcage_task_new "$ROOT" acme ship builder)"
	nixcage_task_set "$ROOT" acme "$id" state ready
	nixcage_task_attempt "$ROOT" acme "$id" 3
	nixcage_task_failed "$ROOT" acme "$id" "ran past its limit" 3
	[ "$(nixcage_task_get "$ROOT" acme "$id" state)" = "ready" ]
	[ "$(nixcage_task_get "$ROOT" acme "$id" attempts)" = "1" ]
}

@test "cancelling is terminal and says so" {
	id="$(nixcage_task_new "$ROOT" acme ship builder)"
	nixcage_task_set "$ROOT" acme "$id" state ready
	run nixcage_task_cancel "$ROOT" acme "$id" "the operator stopped it"
	assert_success
	[ "$(nixcage_task_get "$ROOT" acme "$id" state)" = "cancelled" ]
	[ "$(nixcage_task_get "$ROOT" acme "$id" failure)" = "the operator stopped it" ]
	run nixcage_task_attempt "$ROOT" acme "$id" 2
	assert_failure
}

@test "a task remembers which stage it sits at" {
	id="$(nixcage_task_new "$ROOT" acme ship builder 01)"
	[ "$(nixcage_task_get "$ROOT" acme "$id" stage)" = "01" ]
}

@test "advancing creates the next stage's task and finishes this one" {
	a="$(nixcage_task_new "$ROOT" acme ship architect 00)"
	nixcage_task_set "$ROOT" acme "$a" state awaiting-review
	b="$(nixcage_task_advance "$ROOT" acme "$a" 01 builder)"
	[ "$(nixcage_task_get "$ROOT" acme "$a" state)" = "done" ]
	[ "$(nixcage_task_get "$ROOT" acme "$b" state)" = "proposed" ]
	[ "$(nixcage_task_get "$ROOT" acme "$b" stage)" = "01" ]
	[ "$(nixcage_task_get "$ROOT" acme "$b" role)" = "builder" ]
}

@test "a task created by a stage inherits the workflow it came from" {
	a="$(nixcage_task_new "$ROOT" acme ship architect 00)"
	nixcage_task_set "$ROOT" acme "$a" state awaiting-review
	b="$(nixcage_task_advance "$ROOT" acme "$a" 01 builder)"
	[ "$(nixcage_task_get "$ROOT" acme "$b" workflow)" = "ship" ]
}

@test "a created task names the task it came from" {
	a="$(nixcage_task_new "$ROOT" acme ship architect 00)"
	nixcage_task_set "$ROOT" acme "$a" state awaiting-review
	b="$(nixcage_task_advance "$ROOT" acme "$a" 01 builder)"
	[ "$(nixcage_task_get "$ROOT" acme "$b" parent)" = "$a" ]
}

@test "the acceptance criteria travel with the work" {
	a="$(nixcage_task_new "$ROOT" acme ship architect 00)"
	nixcage_task_set "$ROOT" acme "$a" acceptance "ship the change"
	nixcage_task_set "$ROOT" acme "$a" state awaiting-review
	b="$(nixcage_task_advance "$ROOT" acme "$a" 01 builder)"
	[ "$(nixcage_task_get "$ROOT" acme "$b" acceptance)" = "ship the change" ]
}

@test "a task that has not been worked cannot be advanced" {
	a="$(nixcage_task_new "$ROOT" acme ship architect 00)"
	run nixcage_task_advance "$ROOT" acme "$a" 01 builder
	assert_failure
}

@test "finishing the last stage ends the work rather than inventing a stage" {
	a="$(nixcage_task_new "$ROOT" acme ship reviewer 02)"
	nixcage_task_set "$ROOT" acme "$a" state awaiting-review
	run nixcage_task_advance "$ROOT" acme "$a" "" ""
	assert_success
	assert_output ""
	[ "$(nixcage_task_get "$ROOT" acme "$a" state)" = "done" ]
}

@test "scalars share one file, so a change to several is one write" {
	id="$(nixcage_task_new "$ROOT" acme ship builder)"
	[ -f "$ROOT/acme/$id/fields" ]
	# state must not also exist as its own file, or it is two writes again.
	[ ! -e "$ROOT/acme/$id/state" ]
	[ ! -e "$ROOT/acme/$id/attempts" ]
}

@test "text keeps its own file, since a line-oriented one cannot hold newlines" {
	id="$(nixcage_task_new "$ROOT" acme ship builder)"
	nixcage_task_set "$ROOT" acme "$id" acceptance "$(printf 'one\ntwo')"
	[ -f "$ROOT/acme/$id/acceptance" ]
	[ "$(nixcage_task_get "$ROOT" acme "$id" acceptance)" = "$(printf 'one\ntwo')" ]
}

@test "a scalar carrying a newline is refused rather than corrupting the file" {
	id="$(nixcage_task_new "$ROOT" acme ship builder)"
	run nixcage_task_set "$ROOT" acme "$id" stage "$(printf '01\nrole=evil')"
	assert_failure
	[ "$(nixcage_task_get "$ROOT" acme "$id" role)" = "builder" ]
}

@test "a reader never sees one field from a write and another from the write before" {
	# stage and parent are written together and held equal, so any reader that
	# observes them differing has seen a torn write. A spent attempt with a
	# ready state is NOT the defect -- a failed attempt leaves exactly that.
	id="$(nixcage_task_new "$ROOT" acme ship builder)"
	nixcage_task_set "$ROOT" acme "$id" stage 0 parent 0

	(
		for i in $(seq 1 150); do
			nixcage_task_set "$ROOT" acme "$id" stage "$i" parent "$i"
		done
	) &
	writer=$!

	# One read of the file, both fields from that snapshot. Two separate reads
	# would let the writer advance between them and would test nothing.
	torn=0
	for _ in $(seq 1 150); do
		snapshot="$(cat "$ROOT/acme/$id/fields")"
		a="$(printf '%s\n' "$snapshot" | sed -n 's/^stage=//p')"
		b="$(printf '%s\n' "$snapshot" | sed -n 's/^parent=//p')"
		[ "$a" = "$b" ] || torn=$((torn + 1))
	done
	wait "$writer"
	[ "$torn" -eq 0 ]
}

@test "taking an attempt writes the count and the state together" {
	id="$(nixcage_task_new "$ROOT" acme ship builder)"
	nixcage_task_set "$ROOT" acme "$id" state ready
	before="$(cat "$ROOT/acme/$id/fields")"
	nixcage_task_attempt "$ROOT" acme "$id" 3
	after="$(cat "$ROOT/acme/$id/fields")"
	[ "$before" != "$after" ]
	# Both changed in that one file, not one of them in some other file.
	echo "$after" | grep -q '^attempts=1$'
	echo "$after" | grep -q '^state=running$'
}

@test "id allocation needs no lock and leaves none behind" {
	nixcage_task_new "$ROOT" acme ship builder >/dev/null
	[ ! -e "$ROOT/acme/.seq" ]
	[ ! -e "$ROOT/acme/.seq.lock" ]
}
