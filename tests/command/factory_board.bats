#!/usr/bin/env bats
# The board's web UI (ADR-036): merging is a click there and has no verb.
# Forgejo listens on the factory's bridge, which the host itself reaches
# (ADR-067), so the CLI says the address and how to log in and opens
# nothing else.

load ../test_helper/common

setup() {
	setup_temp_dir
	stub_nixcage
	# What the machine program answers to factory-board: the address, then the password.
	printf '10.77.0.1:3000\nsecret-of-the-day\n' >"$TEST_TEMP_DIR/machine-answer"
}

teardown() {
	teardown_temp_dir
}

@test "factory board prints the board's address on the bridge and the login, and holds nothing open" {
	run_fabriek -f acme board
	assert_success
	assert_line --index 0 'http://10.77.0.1:3000/operator/acme'
	assert_output --partial "operator"
	assert_output --partial "secret-of-the-day"
	refute_output --partial "tunnel"
}

@test "factory board asks the machine for the address rather than guessing one" {
	run_fabriek -f acme board
	assert_success
	run nixcage_calls
	assert_line "/run/current-system/sw/bin/fabriek-container factory-board acme"
}
