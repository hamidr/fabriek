#!/usr/bin/env bats
# The roles a factory declares: what each runs, what toolchain it has to hand,
# and what it can be given to do.
#
# The declaration is a file rather than a directory tree now (ADR-020), and it
# is fed here unvalidated on purpose: these readers guard what they use, so a
# declaration that reached them by some other route still cannot get through.

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/names.sh
	source "$CAGEWORKS_ROOT/modules/names.sh"
	# shellcheck source=../../modules/factory-config.sh
	source "$CAGEWORKS_ROOT/modules/factory-config.sh"
	DECL="$TEST_TEMP_DIR/declaration.json"
	cat >"$DECL" <<'JSON'
{
  "name": "acme",
  "roles": {
    "builder": {
      "command": ["claude", "--permission-mode", "acceptEdits"],
      "provides": ["build"]
    },
    "reviewer": { "provides": ["review", "build"] }
  }
}
JSON
}

teardown() {
	teardown_temp_dir
}

## Replace the declaration with one jq edit applied to it.
declare_with() {
	local edited
	edited="$(jq "$1" "$DECL")"
	printf '%s\n' "$edited" >"$DECL"
}

@test "the declared roles are listed in a stable order" {
	run cageworks_factory_roles "$DECL"
	assert_success
	assert_line --index 0 "builder"
	assert_line --index 1 "reviewer"
}

@test "a role's command is what its declaration says, one word per line" {
	run cageworks_factory_role_command "$DECL" builder
	assert_success
	assert_line --index 0 "claude"
	assert_line --index 1 "--permission-mode"
	assert_line --index 2 "acceptEdits"
}

@test "a role that declares no command gets none, and that is not an error" {
	run cageworks_factory_role_command "$DECL" reviewer
	assert_success
	assert_output ""
}

@test "an undeclared role is refused, and the message says which roles exist" {
	run cageworks_factory_role_command "$DECL" ghost
	assert_failure
	assert_output --partial "builder"
	assert_output --partial "reviewer"
}

@test "a role name that could reach a path or a ref is refused" {
	run cageworks_factory_role_command "$DECL" "../../../etc/passwd"
	assert_failure
}

@test "a declaration with no roles is refused rather than silently empty" {
	declare_with 'del(.roles)'
	run cageworks_factory_roles "$DECL"
	assert_failure
	assert_output --partial "no roles"
}

@test "a specialist role names the devShell it works in" {
	declare_with '.roles.builder.shell = "backend-jvm"'
	run cageworks_factory_role_shell "$DECL" builder
	assert_success
	assert_output "backend-jvm"
}

@test "a role that names no shell gets none, and that is not an error" {
	run cageworks_factory_role_shell "$DECL" reviewer
	assert_success
	assert_output ""
}

# The last place a devShell name is checked before it reaches a flake
# reference, which is why it is checked here as well as in the schema.
@test "a role whose declared shell is not an attribute name is refused" {
	declare_with '.roles.reviewer.shell = "not a name"'
	run cageworks_factory_role_shell "$DECL" reviewer
	assert_failure
	assert_output --partial "reviewer"
}

@test "a role says what it can be given to do" {
	run cageworks_factory_role_provides "$DECL" reviewer
	assert_success
	assert_line --index 0 "review"
	assert_line --index 1 "build"
}

# A stage names a capability rather than a role, so declaring a second role
# that provides it adds capacity without touching the pipeline (ADR-015).
@test "every role providing a capability is offered, in a stable order" {
	run cageworks_factory_roles_providing "$DECL" build
	assert_success
	assert_line --index 0 "builder"
	assert_line --index 1 "reviewer"
}

@test "a capability nobody provides resolves to nobody, and that is not an error" {
	run cageworks_factory_roles_providing "$DECL" telepathy
	assert_success
	assert_output ""
}
