#!/usr/bin/env bats
# Reading a declared factory: its repository, its roles, and what each runs.

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/role-uid.sh
	source "$NIXCAGE_ROOT/modules/role-uid.sh"
	# shellcheck source=../../modules/factory-config.sh
	source "$NIXCAGE_ROOT/modules/factory-config.sh"
	ROOT="$TEST_TEMP_DIR/factories"
	mkdir -p "$ROOT/acme/roles/builder" "$ROOT/acme/roles/reviewer"
	echo "/srv/acme" >"$ROOT/acme/repository"
	printf 'claude\n--permission-mode\nacceptEdits\n' >"$ROOT/acme/roles/builder/command"
	# reviewer declares no command: it gets the ordinary session shell
}

teardown() {
	teardown_temp_dir
}

@test "a factory names the repository it works" {
	run nixcage_factory_repository "$ROOT" acme
	assert_success
	assert_output "/srv/acme"
}

@test "an undeclared factory is refused by name" {
	run nixcage_factory_repository "$ROOT" ghost
	assert_failure
	assert_output --partial "ghost"
}

@test "the declared roles are listed in a stable order" {
	run nixcage_factory_roles "$ROOT" acme
	assert_success
	assert_line --index 0 "builder"
	assert_line --index 1 "reviewer"
}

@test "a role's command is what its declaration says, one word per line" {
	run nixcage_factory_role_command "$ROOT" acme builder
	assert_success
	assert_line --index 0 "claude"
	assert_line --index 1 "--permission-mode"
	assert_line --index 2 "acceptEdits"
}

@test "a role that declares no command gets none, and that is not an error" {
	run nixcage_factory_role_command "$ROOT" acme reviewer
	assert_success
	assert_output ""
}

@test "an undeclared role is refused, and the message says which roles exist" {
	run nixcage_factory_role_command "$ROOT" acme ghost
	assert_failure
	assert_output --partial "builder"
	assert_output --partial "reviewer"
}

@test "a factory name that could escape the declaration tree is refused" {
	run nixcage_factory_repository "$ROOT" "../../etc"
	assert_failure
}

@test "a role name that could escape the declaration tree is refused" {
	run nixcage_factory_role_command "$ROOT" acme "../../../etc/passwd"
	assert_failure
}

@test "a factory declared with no roles is refused rather than silently empty" {
	mkdir -p "$ROOT/bare"
	echo "/srv/bare" >"$ROOT/bare/repository"
	run nixcage_factory_roles "$ROOT" bare
	assert_failure
	assert_output --partial "no roles"
}
