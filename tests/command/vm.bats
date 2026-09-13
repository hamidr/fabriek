#!/usr/bin/env bats
# What an operator can ask about the machines on this host (ADR-019).
#
# Only 'status' exists yet. Building and booting a machine is the rest of
# PRD-004 phase 2, and this file grows the cases the model already names --
# up is idempotent, a stop that cannot complete is reported rather than
# forced, a failed boot leaves the disk alone -- when there is something to
# assert them against.

load ../test_helper/common

setup() {
	setup_temp_dir
	export FABRIEK_MACHINES="$TEST_TEMP_DIR/machines"
}

teardown() {
	teardown_temp_dir
}

@test "a host with no factories started has no machines, and says so quietly" {
	run_fabriek vm status
	assert_success
	assert_output ""
}

@test "the machines here are named, with the port each answers on" {
	# shellcheck source=../../modules/names.sh
	source "$FABRIEK_ROOT/modules/names.sh"
	# shellcheck source=../../modules/machine.sh
	source "$FABRIEK_ROOT/modules/machine.sh"
	fabriek_machine_ensure acme >/dev/null
	fabriek_machine_ensure widgets >/dev/null

	run_fabriek vm status
	assert_success
	assert_line --index 0 --regexp '^acme	port [0-9]+	stopped	no disk yet$'
	assert_line --index 1 --regexp '^widgets	port [0-9]+	stopped	no disk yet$'
}

@test "a machine that has a pool is not one that has yet to be built" {
	# shellcheck source=../../modules/names.sh
	source "$FABRIEK_ROOT/modules/names.sh"
	# shellcheck source=../../modules/machine.sh
	source "$FABRIEK_ROOT/modules/machine.sh"
	fabriek_machine_ensure acme >/dev/null
	: >"$FABRIEK_MACHINES/acme/pool.img"

	run_fabriek vm status
	assert_success
	assert_output --partial "disk"
	refute_output --partial "no disk yet"
}

@test "an unknown vm verb explains itself rather than being passed through" {
	run_fabriek vm boot
	assert_failure
	assert_output --partial "usage"
}

@test "vm is in the help, since it is a verb the dispatcher accepts" {
	run_fabriek help
	assert_success
	assert_output --partial "vm status"
}
