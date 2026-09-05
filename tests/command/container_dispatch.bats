#!/usr/bin/env bats
# The guest program's own surface. It is what the CLI reaches over nixcage's
# transport, so a verb the CLI sends and this does not dispatch fails inside
# the VM with a usage message nobody typed.

load ../test_helper/common

setup() {
	setup_temp_dir
	export CAGEWORKS_LIB="$CAGEWORKS_ROOT/modules"
	export CAGEWORKS_STATE="$TEST_TEMP_DIR/state"
	export CAGEWORKS_FACTORIES="$TEST_TEMP_DIR/factories"
	export CAGEWORKS_CONFIG="$TEST_TEMP_DIR/supervisor"
	mkdir -p "$CAGEWORKS_STATE" "$CAGEWORKS_FACTORIES"
}

teardown() {
	teardown_temp_dir
}

@test "no verb prints the usage rather than doing something" {
	run_cageworks_container
	assert_failure
	assert_output --partial "usage: cageworks-container"
}

@test "an unknown verb prints the usage rather than guessing" {
	run_cageworks_container frobnicate acme
	assert_failure
	assert_output --partial "usage: cageworks-container"
}

@test "every verb the operator's CLI sends is one the guest dispatches" {
	# Derived from both files rather than listed here, so a verb added to one
	# and not the other fails at the seam instead of inside the VM.
	local sent dispatched
	sent="$(grep -oE 'cageworks-container [a-z-]+|guest "?(factory-\$sub|[a-z-]+)"?' "$CAGEWORKS_BIN" |
		grep -oE '[a-z]+-[a-z-]+' | grep -v '^cageworks-container$' | sort -u)"
	dispatched="$(grep -oE "^$(printf '\t')[a-z-]+\)" "$CAGEWORKS_CONTAINER_BIN" |
		tr -d "$(printf '\t')" | tr -d ')' | sort -u)"
	[ -n "$sent" ]
	for verb in $sent; do
		# The CLI builds this one from its subcommand, so it is checked below.
		[ "$verb" = "factory-sub" ] && continue
		[[ "$dispatched" == *"$verb"* ]] || {
			echo "the guest does not dispatch: $verb"
			return 1
		}
	done
}

@test "the four factory verbs the CLI builds by name are all dispatched" {
	# 'guest "factory-$sub"' is one call site for four verbs, so the names
	# never appear in the CLI and nothing above can see them.
	for sub in status sync resume reports; do
		run grep -qE "^$(printf '\t')factory-$sub\)" "$CAGEWORKS_CONTAINER_BIN"
		assert_success
	done
}

@test "every verb the guest dispatches is in its usage" {
	# The usage is the only description of this surface anything sees at run
	# time, and the CLI is not the only caller: a person on the machine the
	# cages are on can type it too.
	run_cageworks_container
	local usage="$output"
	local dispatched
	dispatched="$(grep -oE "^$(printf '\t')[a-z-]+\)" "$CAGEWORKS_CONTAINER_BIN" |
		tr -d "$(printf '\t')" | tr -d ')' | sort -u)"
	for verb in $dispatched; do
		[[ "$usage" == *"$verb"* ]] || {
			echo "the usage does not mention: $verb"
			return 1
		}
	done
}

@test "a verb that needs a declaration says so rather than failing obscurely" {
	run_cageworks_container role-worktree acme builder "$TEST_TEMP_DIR/nowhere"
	assert_failure
	assert_output --partial "repository not found"
}

@test "role-enter without a factory and a role prints the usage" {
	run_cageworks_container role-enter
	assert_failure
	assert_output --partial "usage: cageworks-container"
}
