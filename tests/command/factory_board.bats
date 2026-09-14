#!/usr/bin/env bats
# The board's web UI from the operator's host (ADR-036): merging is a click
# there and has no verb, and Forgejo listens on the bridge where only the
# factory's own ssh reaches, so the CLI tunnels a local port to it over the
# same key and port every other verb uses, and says where and how to log in.

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

@test "factory board tunnels a local port to the board over the factory's own ssh and prints the URL and the login" {
	run_fabriek -f acme board
	assert_success
	assert_output --regexp 'http://127\.0\.0\.1:[0-9]+/operator/acme'
	assert_output --partial "operator"
	assert_output --partial "secret-of-the-day"
	run ssh_flags
	assert_output --regexp -- '-N -L 127\.0\.0\.1:[0-9]+:10\.77\.0\.1:3000 root@localhost'
	assert_output --partial "-i $FABRIEK_MACHINES/acme/id_ed25519"
	assert_output --partial "-p 22100"
}

@test "factory board asks the machine for the address rather than guessing one" {
	run_fabriek -f acme board
	assert_success
	run nixcage_calls
	assert_line "fabriek-container factory-board acme"
}
