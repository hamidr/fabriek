#!/usr/bin/env bats
# Reading a declared factory: its repository, its roles, and what each runs.

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/names.sh
	source "$CAGEWORKS_ROOT/modules/names.sh"
	# shellcheck source=../../modules/factory-config.sh
	source "$CAGEWORKS_ROOT/modules/factory-config.sh"
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
	run cageworks_factory_repository "$ROOT" acme
	assert_success
	assert_output "/srv/acme"
}

@test "an undeclared factory is refused by name" {
	run cageworks_factory_repository "$ROOT" ghost
	assert_failure
	assert_output --partial "ghost"
}

@test "the declared roles are listed in a stable order" {
	run cageworks_factory_roles "$ROOT" acme
	assert_success
	assert_line --index 0 "builder"
	assert_line --index 1 "reviewer"
}

@test "a role's command is what its declaration says, one word per line" {
	run cageworks_factory_role_command "$ROOT" acme builder
	assert_success
	assert_line --index 0 "claude"
	assert_line --index 1 "--permission-mode"
	assert_line --index 2 "acceptEdits"
}

@test "a role that declares no command gets none, and that is not an error" {
	run cageworks_factory_role_command "$ROOT" acme reviewer
	assert_success
	assert_output ""
}

@test "an undeclared role is refused, and the message says which roles exist" {
	run cageworks_factory_role_command "$ROOT" acme ghost
	assert_failure
	assert_output --partial "builder"
	assert_output --partial "reviewer"
}

@test "a factory name that could escape the declaration tree is refused" {
	run cageworks_factory_repository "$ROOT" "../../etc"
	assert_failure
}

@test "a role name that could escape the declaration tree is refused" {
	run cageworks_factory_role_command "$ROOT" acme "../../../etc/passwd"
	assert_failure
}

@test "a factory declared with no roles is refused rather than silently empty" {
	mkdir -p "$ROOT/bare"
	echo "/srv/bare" >"$ROOT/bare/repository"
	run cageworks_factory_roles "$ROOT" bare
	assert_failure
	assert_output --partial "no roles"
}

@test "the example configuration shows how a factory is declared" {
	example="$CAGEWORKS_ROOT/examples/config/flake.nix"
	run grep -c "factories.acme" "$example"
	assert_success
	# The uid a role is mapped onto comes from nixcage, so a configuration
	# that declares a factory and not the range it draws from does not build.
	run grep -c "principalUidRange" "$example"
	assert_success
	# A command is argv, and the example must not teach otherwise.
	run grep -E 'command = \[' "$example"
	assert_success
}

@test "the example configuration imports both modules, since it needs both" {
	example="$CAGEWORKS_ROOT/examples/config/flake.nix"
	run grep -c "nixosModules.cageworks" "$example"
	assert_success
	run grep -cE "nixcage.nixosModules.(nixcage|host)" "$example"
	assert_success
}

@test "a specialist role names the devShell it works in" {
	echo "backend-jvm" >"$ROOT/acme/roles/builder/shell"
	run cageworks_factory_role_shell "$ROOT" acme builder
	assert_success
	assert_output "backend-jvm"
}

@test "a role that names no shell gets none, and that is not an error" {
	run cageworks_factory_role_shell "$ROOT" acme reviewer
	assert_success
	assert_output ""
}

@test "a role whose declared shell is not an attribute name is refused" {
	printf 'not a name\n' >"$ROOT/acme/roles/reviewer/shell"
	run cageworks_factory_role_shell "$ROOT" acme reviewer
	assert_failure
	assert_output --partial "reviewer"
}

@test "a shell is only read for a role the factory declares" {
	run cageworks_factory_role_shell "$ROOT" acme ghost
	assert_failure
}

@test "the example repository shows one devShell per specialist" {
	example="$CAGEWORKS_ROOT/examples/factory-project/flake.nix"
	run grep -c "backend-jvm" "$example"
	assert_success
	# A specialist shell is only useful next to a default one: a role that
	# declares none must still have somewhere to land.
	run grep -E "^ *default = " "$example"
	assert_success
}

@test "a role declares what it can do" {
	printf 'build\nreview\n' >"$ROOT/acme/roles/builder/provides"
	run cageworks_factory_role_provides "$ROOT" acme builder
	assert_success
	assert_line --index 0 "build"
	assert_line --index 1 "review"
}

@test "a role that declares nothing can do nothing, and that is not an error" {
	run cageworks_factory_role_provides "$ROOT" acme reviewer
	assert_success
	assert_output ""
}

@test "a capability resolves to the roles providing it, in declaration order" {
	printf 'build\n' >"$ROOT/acme/roles/builder/provides"
	printf 'build\n' >"$ROOT/acme/roles/reviewer/provides"
	run cageworks_factory_roles_providing "$ROOT" acme build
	assert_success
	assert_line --index 0 "builder"
	assert_line --index 1 "reviewer"
}

@test "a capability nothing provides resolves to nobody" {
	printf 'build\n' >"$ROOT/acme/roles/builder/provides"
	run cageworks_factory_roles_providing "$ROOT" acme design
	assert_success
	assert_output ""
}
