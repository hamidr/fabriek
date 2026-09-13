#!/usr/bin/env bats
# The machine program's own surface. It is what the CLI reaches over nixcage's
# transport, so a verb the CLI sends and this does not dispatch fails inside
# the VM with a usage message nobody typed.

load ../test_helper/common

setup() {
	setup_temp_dir
	export FABRIEK_LIB="$FABRIEK_ROOT/modules"
	export FABRIEK_STATE="$TEST_TEMP_DIR/state"
	export FABRIEK_CONFIG="$TEST_TEMP_DIR/supervisor"
	mkdir -p "$FABRIEK_STATE"
}

teardown() {
	teardown_temp_dir
}

@test "no verb prints the usage rather than doing something" {
	run_fabriek_container
	assert_failure
	assert_output --partial "usage: fabriek-container"
}

@test "an unknown verb prints the usage rather than guessing" {
	run_fabriek_container frobnicate acme
	assert_failure
	assert_output --partial "usage: fabriek-container"
}

@test "every verb the operator's CLI sends is one the machine dispatches" {
	# Derived from both files rather than listed here, so a verb added to one
	# and not the other fails at the seam instead of inside the VM.
	local sent dispatched
	sent="$(grep -oE 'fabriek-container [a-z-]+|machine "?(factory-\$sub|[a-z-]+)"?' "$FABRIEK_BIN" |
		grep -oE '[a-z]+-[a-z-]+' | grep -v '^fabriek-container$' | sort -u)"
	dispatched="$(grep -oE "^$(printf '\t')[a-z-]+\)" "$FABRIEK_CONTAINER_BIN" |
		tr -d "$(printf '\t')" | tr -d ')' | sort -u)"
	[ -n "$sent" ]
	for verb in $sent; do
		[[ "$dispatched" == *"$verb"* ]] || {
			echo "the machine does not dispatch: $verb"
			return 1
		}
	done
}

@test "every verb the machine dispatches is in its usage" {
	# The usage is the only description of this surface anything sees at run
	# time, and the CLI is not the only caller: a person on the machine the
	# cages are on can type it too.
	run_fabriek_container
	local usage="$output"
	local dispatched
	dispatched="$(grep -oE "^$(printf '\t')[a-z-]+\)" "$FABRIEK_CONTAINER_BIN" |
		tr -d "$(printf '\t')" | tr -d ')' | sort -u)"
	for verb in $dispatched; do
		[[ "$usage" == *"$verb"* ]] || {
			echo "the usage does not mention: $verb"
			return 1
		}
	done
}

@test "a verb that needs a declaration says so rather than failing obscurely" {
	run_fabriek_container role-worktree acme builder "$TEST_TEMP_DIR/nowhere"
	assert_failure
	assert_output --partial "repository not found"
}

@test "role-enter without a factory and a role prints the usage" {
	run_fabriek_container role-enter
	assert_failure
	assert_output --partial "usage: fabriek-container"
}
