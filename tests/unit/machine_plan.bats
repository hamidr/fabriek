#!/usr/bin/env bats
# What a session takes from the plan and the declaration the build put on
# the machine (ADR-040): here the bounds a cage gets on its scope (nixcage
# ADR-012), sized from what the factory declared it may use at once.

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/names.sh
	source "$FABRIEK_ROOT/modules/names.sh"
	# shellcheck source=../../modules/sizes.sh
	source "$FABRIEK_ROOT/modules/sizes.sh"
	# shellcheck source=../../modules/machine-plan.sh
	source "$FABRIEK_ROOT/modules/machine-plan.sh"
	DECL="$TEST_TEMP_DIR/declaration.json"
}

teardown() {
	teardown_temp_dir
}

declare_resources() {
	printf '{ "name": "acme", "roles": { "builder": { "provides": ["build"] } }, "resources": %s }\n' "$1" >"$DECL"
}

@test "a cage gets the machine's memory and cores divided by how many cages may run at once" {
	declare_resources '{ "memory": "8G", "cores": 4, "concurrency": 2 }'
	run fabriek_cage_bounds "$DECL"
	assert_success
	assert_line --index 0 "--memory"
	assert_line --index 1 "4096M"
	assert_line --index 2 "--cpus"
	assert_line --index 3 "2"
}

@test "a cage never gets less than one cpu, however many may run at once" {
	declare_resources '{ "memory": "8G", "cores": 2, "concurrency": 3 }'
	run fabriek_cage_bounds "$DECL"
	assert_line --index 3 "1"
}

# ADR-055: every role's session runs from up, so with no ceiling declared
# every role may be busy at once and the machine is shared by all of them.
@test "with no concurrency declared, every role may be busy at once, so a cage gets the machine divided by the roles" {
	printf '{ "name": "acme", "roles": { "a": { "provides": ["build"] }, "b": { "provides": ["build"] }, "c": { "provides": ["review"] } }, "resources": { "memory": "3G", "cores": 3 } }\n' >"$DECL"
	run fabriek_cage_bounds "$DECL"
	assert_line --index 1 "1024M"
	assert_line --index 3 "1"
}

@test "with no concurrency declared and one role, that role gets everything" {
	declare_resources '{ "memory": "2G", "cores": 3 }'
	run fabriek_cage_bounds "$DECL"
	assert_line --index 1 "2048M"
	assert_line --index 3 "3"
}

@test "with no memory or cores declared, a cage is bounded by the machine alone" {
	declare_resources '{ "concurrency": 2 }'
	run fabriek_cage_bounds "$DECL"
	assert_success
	assert_output ""
}
