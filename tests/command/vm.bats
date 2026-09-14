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
	run_fabriek ps
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

	run_fabriek ps
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

	run_fabriek ps
	assert_success
	assert_output --partial "disk"
	refute_output --partial "no disk yet"
}

@test "ps takes no arguments, and says so with a usage exit" {
	run_fabriek ps extra
	[ "$status" -eq 2 ]
	assert_output --partial "usage: fabriek ps"
}

@test "ps --json is the same machines as a structure" {
	# shellcheck source=../../modules/names.sh
	source "$FABRIEK_ROOT/modules/names.sh"
	# shellcheck source=../../modules/machine.sh
	source "$FABRIEK_ROOT/modules/machine.sh"
	fabriek_machine_ensure acme >/dev/null
	run_fabriek ps --json
	assert_success
	run jq -c '[.[0].factory, .[0].state, (.[0].port | type)]' <<<"$output"
	assert_output '["acme","stopped","number"]'
}

@test "ps is in the help, since it is a verb the dispatcher accepts" {
	run_fabriek help
	assert_success
	assert_output --partial "  ps"
}
