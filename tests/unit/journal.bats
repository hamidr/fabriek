#!/usr/bin/env bats
# The ledger a role writes to and cannot edit (ADR-027 points 4, 5 and 6).

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/names.sh
	source "$CAGEWORKS_ROOT/modules/names.sh"
	# shellcheck source=../../modules/journal.sh
	source "$CAGEWORKS_ROOT/modules/journal.sh"
}

teardown() {
	teardown_temp_dir
}

@test "the journal is namespaced by the factory that writes it" {
	run cageworks_journal_namespace acme
	assert_success
	assert_output "acme"
}

@test "a factory name that would reach a path is refused where it is read" {
	run cageworks_journal_namespace ../etc
	assert_failure
}

@test "a role session is handed the socket of its own factory's journal" {
	run cageworks_journal_args acme
	assert_success
	# One argv word per line, because nixcage takes a flag and its value as
	# separate arguments and nothing in either is ever re-split.
	assert_line --index 0 "--bind"
	assert_line --index 1 "/run/systemd/journal.acme/socket:/run/systemd/journal/socket"
	[ "${#lines[@]}" -eq 2 ]
}

@test "the socket lands where libsystemd looks, whatever it is called outside" {
	# A cage has a /run of its own, so the namespaced path on the machine has
	# to arrive under the name journald's own client code opens.
	run cageworks_journal_args acme
	assert_success
	assert_output --partial ":/run/systemd/journal/socket"
}

@test "the bind is writable, because connecting to a socket needs it" {
	# --bind-ro would leave a socket nothing in the cage can connect to, and
	# the failure would look like a missing ledger rather than a wrong flag.
	run cageworks_journal_args acme
	assert_success
	refute_line "--bind-ro"
}

@test "one factory is never handed another factory's journal" {
	run cageworks_journal_args other
	assert_success
	refute_output --partial "journal.acme"
	assert_output --partial "journal.other"
}

@test "a factory name that would escape the namespace is refused" {
	run cageworks_journal_args "acme/../root"
	assert_failure
}
