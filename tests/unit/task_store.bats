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
