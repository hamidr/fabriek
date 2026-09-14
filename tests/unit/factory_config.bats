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
	source "$FABRIEK_ROOT/modules/names.sh"
	# shellcheck source=../../modules/factory-config.sh
	source "$FABRIEK_ROOT/modules/factory-config.sh"
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
	run fabriek_factory_roles "$DECL"
	assert_success
	assert_line --index 0 "builder"
	assert_line --index 1 "reviewer"
}

@test "a role's command is what its declaration says, one word per line" {
	run fabriek_factory_role_command "$DECL" builder
	assert_success
	assert_line --index 0 "claude"
	assert_line --index 1 "--permission-mode"
	assert_line --index 2 "acceptEdits"
}

# ADR-029 fixed the agent and ADR-030 put it on every cage, so a role that
# says nothing runs it (ADR-042 point 9), composed by the machine with the
# model its build chose; the declaration's side says nothing about it.
@test "a role that declares no command prints none, and the machine runs the agent" {
	run fabriek_factory_role_command "$DECL" reviewer
	assert_success
	assert_output ""
}

@test "an undeclared role is refused, and the message says which roles exist" {
	run fabriek_factory_role_command "$DECL" ghost
	assert_failure
	assert_output --partial "builder"
	assert_output --partial "reviewer"
}

@test "a role name that could reach a path or a ref is refused" {
	run fabriek_factory_role_command "$DECL" "../../../etc/passwd"
	assert_failure
}

@test "a declaration with no roles is refused rather than silently empty" {
	declare_with 'del(.roles)'
	run fabriek_factory_roles "$DECL"
	assert_failure
	assert_output --partial "no roles"
}

@test "a specialist role names the devShell it works in" {
	declare_with '.roles.builder.shell = "backend-jvm"'
	run fabriek_factory_role_shell "$DECL" builder
	assert_success
	assert_output "backend-jvm"
}

@test "a role that names no shell gets none, and that is not an error" {
	run fabriek_factory_role_shell "$DECL" reviewer
	assert_success
	assert_output ""
}

# The last place a devShell name is checked before it reaches a flake
# reference, which is why it is checked here as well as in the schema.
@test "a role whose declared shell is not an attribute name is refused" {
	declare_with '.roles.reviewer.shell = "not a name"'
	run fabriek_factory_role_shell "$DECL" reviewer
	assert_failure
	assert_output --partial "reviewer"
}

@test "a role names the specialists it is composed of, one per line" {
	declare_with '.roles.builder.specialists = ["java", "python"]'
	run fabriek_factory_role_specialists "$DECL" builder
	assert_success
	assert_line --index 0 "java"
	assert_line --index 1 "python"
}

@test "a role naming no specialist has none, and that is not an error" {
	run fabriek_factory_role_specialists "$DECL" reviewer
	assert_success
	assert_output ""
}

# A specialist name becomes a directory name under a catalogue.
@test "a specialist name that is not a usable name is refused, naming the role" {
	declare_with '.roles.reviewer.specialists = ["../developer"]'
	run fabriek_factory_role_specialists "$DECL" reviewer
	assert_failure
	assert_output --partial "reviewer"
}

@test "a role says what it can be given to do" {
	run fabriek_factory_role_provides "$DECL" reviewer
	assert_success
	assert_line --index 0 "review"
	assert_line --index 1 "build"
}

# A stage names a capability rather than a role, so declaring a second role
# that provides it adds capacity without touching the pipeline (ADR-015).
@test "every role providing a capability is offered, in a stable order" {
	run fabriek_factory_roles_providing "$DECL" build
	assert_success
	assert_line --index 0 "builder"
	assert_line --index 1 "reviewer"
}

@test "a capability nobody provides resolves to nobody, and that is not an error" {
	run fabriek_factory_roles_providing "$DECL" telepathy
	assert_success
	assert_output ""
}
