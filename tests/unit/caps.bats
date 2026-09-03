#!/usr/bin/env bats
# The caps that stop a factory: how many runs at once, and how much a workflow
# may spend (PRD-003 phase 5).

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/role-uid.sh
	source "$NIXCAGE_ROOT/modules/role-uid.sh"
	# shellcheck source=../../modules/caps.sh
	source "$NIXCAGE_ROOT/modules/caps.sh"
	ROOT="$TEST_TEMP_DIR/caps"
}

teardown() {
	teardown_temp_dir
}

@test "a machine with nothing running has no runs in flight" {
	run nixcage_cap_active "$ROOT"
	assert_success
	assert_output "0"
}

@test "claiming a slot puts a run in flight, releasing takes it out" {
	nixcage_cap_claim "$ROOT" acme task-0001 2
	[ "$(nixcage_cap_active "$ROOT")" = "1" ]
	nixcage_cap_release "$ROOT" acme task-0001
	[ "$(nixcage_cap_active "$ROOT")" = "0" ]
}

@test "the cap is global, not per factory" {
	nixcage_cap_claim "$ROOT" acme task-0001 2
	nixcage_cap_claim "$ROOT" other task-0001 2
	run nixcage_cap_claim "$ROOT" third task-0001 2
	assert_failure
	assert_output --partial "2"
}

@test "a refused claim leaves nothing behind" {
	nixcage_cap_claim "$ROOT" acme task-0001 1
	nixcage_cap_claim "$ROOT" acme task-0002 1 || true
	[ "$(nixcage_cap_active "$ROOT")" = "1" ]
}

@test "releasing a slot that was never claimed is not an error" {
	run nixcage_cap_release "$ROOT" acme task-0009
	assert_success
}

@test "claiming the same run twice does not consume two slots" {
	nixcage_cap_claim "$ROOT" acme task-0001 3
	nixcage_cap_claim "$ROOT" acme task-0001 3
	[ "$(nixcage_cap_active "$ROOT")" = "1" ]
}

@test "a workflow that has spent nothing has spent nothing" {
	run nixcage_cap_spent "$ROOT" acme ship runs
	assert_success
	assert_output "0"
}

@test "spending accumulates and is remembered" {
	nixcage_cap_spend "$ROOT" acme ship runs 1 10
	nixcage_cap_spend "$ROOT" acme ship runs 2 10
	[ "$(nixcage_cap_spent "$ROOT" acme ship runs)" = "3" ]
}

@test "spending past the allowance is refused, and nothing is spent" {
	nixcage_cap_spend "$ROOT" acme ship runs 2 3
	run nixcage_cap_spend "$ROOT" acme ship runs 2 3
	assert_failure
	assert_output --partial "ship"
	[ "$(nixcage_cap_spent "$ROOT" acme ship runs)" = "2" ]
}

@test "an exhausted workflow does not stop the others" {
	nixcage_cap_spend "$ROOT" acme ship runs 3 3
	run nixcage_cap_spend "$ROOT" acme ship runs 1 3
	assert_failure
	run nixcage_cap_spend "$ROOT" acme release runs 1 3
	assert_success
}

@test "an allowance of zero means unbounded, since a workflow with no budget declared is not a workflow that may not run" {
	nixcage_cap_spend "$ROOT" acme ship runs 99 0
	[ "$(nixcage_cap_spent "$ROOT" acme ship runs)" = "99" ]
}

@test "runs and tokens are counted apart" {
	nixcage_cap_spend "$ROOT" acme ship runs 1 10
	nixcage_cap_spend "$ROOT" acme ship tokens 5000 100000
	[ "$(nixcage_cap_spent "$ROOT" acme ship runs)" = "1" ]
	[ "$(nixcage_cap_spent "$ROOT" acme ship tokens)" = "5000" ]
}

@test "a factory name that could escape the cap directory is refused" {
	run nixcage_cap_claim "$ROOT" "../../etc" task-0001 2
	assert_failure
}
