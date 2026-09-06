#!/usr/bin/env bats
# The factory a repository declares about itself (ADR-020).
#
# Validation is pure: JSON in, either normalised JSON out or a message naming
# what was wrong. Reading is the only part that needs nix and a git repository,
# and it is separated so that the schema can be tested without either.

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/names.sh
	source "$CAGEWORKS_ROOT/modules/names.sh"
	# shellcheck source=../../modules/schema.sh
	source "$CAGEWORKS_ROOT/modules/schema.sh"
	# shellcheck source=../../modules/resources.sh
	source "$CAGEWORKS_ROOT/modules/resources.sh"
	# shellcheck source=../../modules/repo-declaration.sh
	source "$CAGEWORKS_ROOT/modules/repo-declaration.sh"
}

teardown() {
	teardown_temp_dir
}

## A declaration somebody would actually write. Every test starts here and
## changes one thing, so what a test is about is exactly what it edits.
complete_declaration() {
	cat <<'JSON'
{
  "name": "acme",
  "roles": {
    "architect": { "command": ["claude"], "provides": ["design"] },
    "backend": {
      "command": ["claude"],
      "provides": ["build"],
      "shell": "backend-jvm"
    }
  },
  "workflows": {
    "ship": {
      "stages": [
        { "needs": "design", "done": "the approach is written down" },
        { "needs": "build", "ready": ["acceptance"], "done": "tests pass" }
      ],
      "budget": { "runs": 200 },
      "consults": { "backend": ["architect"] }
    }
  },
  "resources": {
    "memory": "8G",
    "cores": 4,
    "roleQuota": "20G",
    "concurrency": 3
  }
}
JSON
}

## Validate the complete declaration with one jq edit applied to it.
validate_with() {
	complete_declaration | jq "$1" | cageworks_declaration_validate
}

@test "a complete declaration is accepted and comes back as itself" {
	run validate_with '.'
	assert_success
	assert_output --partial '"name"'
	assert_output --partial 'acme'
}

@test "everything but the roles that work the repository is optional" {
	run validate_with 'del(.resources, .workflows)'
	assert_success
}

@test "a repository declaring no roles is a declaration mistake, not a factory" {
	run validate_with 'del(.roles)'
	assert_failure
	assert_output --partial "roles"
}

# The closed schema is the whole security argument of ADR-020 point 2: a
# repository cannot reach the machine it is given. A key nobody recognises
# being ignored rather than refused would let one try.
@test "an unknown key at the top is refused, and the message names it" {
	run validate_with '.systemPackages = ["nmap"]'
	assert_failure
	assert_output --partial "systemPackages"
}

@test "an unknown key inside a role is refused, naming the role and the key" {
	run validate_with '.roles.backend.privileged = true'
	assert_failure
	assert_output --partial "backend"
	assert_output --partial "privileged"
}

@test "an unknown key inside a workflow is refused, naming the workflow" {
	run validate_with '.workflows.ship.schedule = "hourly"'
	assert_failure
	assert_output --partial "ship"
	assert_output --partial "schedule"
}

@test "an unknown key inside a stage is refused" {
	run validate_with '.workflows.ship.stages[0].runAs = "root"'
	assert_failure
	assert_output --partial "runAs"
}

@test "an unknown key inside resources is refused" {
	run validate_with '.resources.kernelModules = ["kvm"]'
	assert_failure
	assert_output --partial "kernelModules"
}

# ADR-020 point 1: the repository doing the declaring is the repository worked,
# so there is nothing left for it to point at. A declaration still carrying the
# old field is refused rather than silently obeyed.
@test "a declaration naming a repository is refused, since it is one" {
	run validate_with '.repository = "/srv/other"'
	assert_failure
	assert_output --partial "repository"
}

@test "a factory name that could reach a path or a ref is refused" {
	run validate_with '.name = "../../etc"'
	assert_failure
	assert_output --partial "name"
}

@test "a role name that could reach a path or a ref is refused" {
	run validate_with '{name, roles: {"../etc": .roles.backend}}'
	assert_failure
}

@test "a devShell name that could reach somebody else's flake is refused" {
	run validate_with '.roles.backend.shell = "github:evil/flake#sh"'
	assert_failure
	assert_output --partial "shell"
}

# A declared command is argv, one word per element, so a shell line written
# where a list belongs is refused rather than re-split on the way through.
@test "a command written as a shell line instead of argv is refused" {
	run validate_with '.roles.backend.command = "claude --dangerously-skip"'
	assert_failure
	assert_output --partial "command"
}

@test "a role that provides nothing is refused, naming the role" {
	run validate_with '.roles.backend.provides = []'
	assert_failure
	assert_output --partial "backend"
}

@test "a stage that needs no capability is refused" {
	run validate_with 'del(.workflows.ship.stages[0].needs)'
	assert_failure
	assert_output --partial "needs"
}

# ADR-015, kept by ADR-023 decision 7: a stage no declared role can work is
# rejected when the declaration is read rather than when it fires.
@test "a stage needing a capability no declared role provides is refused" {
	run validate_with '.workflows.ship.stages[0].needs = "telepathy"'
	assert_failure
	assert_output --partial "telepathy"
}

@test "a consult naming a role that does not exist is refused" {
	run validate_with '.workflows.ship.consults.backend = ["ghost"]'
	assert_failure
	assert_output --partial "ghost"
}

@test "a workflow declaring no stages is refused, naming the workflow" {
	run validate_with '.workflows.ship.stages = []'
	assert_failure
	assert_output --partial "ship"
}
