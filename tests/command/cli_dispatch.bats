#!/usr/bin/env bats
# Top-level CLI dispatch: help, version, unknown commands, and the one thing
# the CLI is allowed to know about how a cage is reached.

load ../test_helper/common

setup() {
	setup_temp_dir
	stub_nixcage
}

teardown() {
	teardown_temp_dir
}

@test "no arguments shows help" {
	run_cageworks
	assert_success
	assert_output --partial "Usage:"
}

@test "every command the dispatcher accepts is in the help" {
	# Derived from the dispatcher rather than listed here, so adding a command
	# without documenting it fails instead of quietly shipping undiscoverable.
	run_cageworks help
	assert_success
	local commands
	commands="$(sed -n '/^  local command=/,/^  esac/p' "$CAGEWORKS_BIN" |
		grep -oE '^  [a-z|-]+\)' | tr -d ' )' | tr '|' '\n' | grep -vE '^(--|-)')"
	[ -n "$commands" ]
	for cmd in $commands; do
		case "$cmd" in
		help | version) continue ;;
		esac
		[[ "$output" == *"$cmd"* ]] || {
			echo "the help does not mention: $cmd"
			return 1
		}
	done
}

@test "the help advertises nothing the dispatcher would reject" {
	run_cageworks help
	for word in enter rebuild down status; do
		[[ "$output" != *" $word "* ]]
	done
}

@test "version prints the version" {
	run_cageworks version
	assert_success
	assert_output --partial "cageworks "
}

@test "unknown command fails with help" {
	run_cageworks frobnicate
	assert_failure
	assert_output --partial "Unknown command"
}

@test "every guest command goes through nixcage exec and nothing else" {
	# The transport is the only thing cageworks knows about where the cages
	# are. A second way to reach them would be a second thing to keep true.
	run grep -cE '"\$NIXCAGE" exec' "$CAGEWORKS_BIN"
	assert_output "2"
	# Comments stripped: what matters is what runs, and both words are worth
	# writing about in prose.
	run bash -c "grep -vE '^[[:space:]]*#' '$CAGEWORKS_BIN' | grep -cE '(^|[^a-z])(ssh|sudo)[[:space:]]'"
	assert_output "0"
}

@test "nothing here reads nixcage's own state" {
	# Reading the VM's port, key or state layout is the coupling the split
	# exists to remove.
	run grep -c 'XDG_STATE_HOME\|state/nixcage\|/var/lib/nixcage' "$CAGEWORKS_BIN"
	assert_output "0"
}
