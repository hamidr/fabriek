#!/usr/bin/env bats
# What a role can be, shown on the operator's host without a build (task 3):
# fabriek catalogue list and show over the shipped catalogue and a
# repository's own, and fabriek role show for a composed role of a registered
# factory at its commit. Evaluated for real.

load ../test_helper/common

setup() {
	setup_temp_dir
	export FABRIEK_SELF="$FABRIEK_ROOT"
	REPO="$TEST_TEMP_DIR/acme"
	mkdir -p "$REPO/fabriek/catalogue/specialists/local" "$REPO/fabriek/catalogue/skills/release-here"
	git init -q "$REPO"
	git -C "$REPO" config user.name factory
	git -C "$REPO" config user.email factory@invalid
	printf 'I release here.\n' >"$REPO/fabriek/catalogue/specialists/local/PROMPT.md"
	printf '{ specialists, skills, ... }: { extends = [ specialists.python ]; skills = [ skills.release-here ]; prompt = ./PROMPT.md; }\n' >"$REPO/fabriek/catalogue/specialists/local/default.nix"
	printf -- '---\nname: release-here\ndescription: Cut a release of this repository.\n---\n# Release\n' >"$REPO/fabriek/catalogue/skills/release-here/SKILL.md"
	printf '{ ... }: { src = ./.; }\n' >"$REPO/fabriek/catalogue/skills/release-here/default.nix"
	cat >"$REPO/fabriek.toml" <<'TOML'
name = "acme"
catalogue = "fabriek/catalogue"

[roles.backend]
provides = ["build"]
specialists = ["local"]

[[workflows.ship.stages]]
needs = "build"
TOML
	git -C "$REPO" add -A
	git -C "$REPO" -c commit.gpgsign=false commit -qm declare
	printf '[factories.acme]\npath = "%s"\n' "$REPO" >"$FABRIEK_CONFIG"
}

teardown() {
	teardown_temp_dir
}

fab() {
	run bash "$FABRIEK_ROOT/fabriek" "$@"
}

@test "ls names every shipped specialist with its parents and every skill with its description" {
	fab ls
	assert_success
	assert_line --partial "django: extends python"
	assert_line --partial "committer:"
	assert_line --partial "developer: extends committer"
	assert_line --partial "manager: extends committer"
	assert_line --partial "workflow-tuning:"
	assert_line --partial "debugging: Find the cause before touching a fix"
	assert_line --partial "proof-before-done:"
	assert_line --partial "task-splitting:"
	assert_line --partial "review-findings: Work a reviewer's findings"
	assert_line --partial "tdd: Write the failing test first"
	refute_output --partial "  local:"
}

@test "ls with a repository adds its own entries, read at the commit" {
	fab ls "$REPO"
	assert_success
	assert_line --partial "local: extends python"
	assert_line --partial "release-here: Cut a release"
}

@test "show says what a specialist brings: order, tools, skills, servers, tests, and the prompt" {
	fab show springboot
	assert_success
	assert_line --partial "order: committer, developer, java, springboot"
	assert_line --partial "tools:"
	assert_output --partial "maven"
	## ADR-049: every specialist builds on developer, and developer carries
	## the binary the codegraph tools spawn.
	assert_output --partial "codegraph"
	assert_line --partial "jvm-profile: Profile a running JVM"
	assert_line --partial "servers: jdtls"
	assert_line --partial "tests: **/src/test/**"
	assert_output --partial "## committer"
	assert_output --partial "## developer"
	assert_output --partial "You develop Spring Boot applications."
}

@test "show of a name no catalogue has is refused naming what is offered" {
	fab show rust
	assert_failure
	assert_output --partial "offers: architect, committer, developer"
}

@test "show -f composes a registered factory's role at its commit, its own catalogue included" {
	fab -f acme show backend
	assert_success
	assert_line --partial "order: committer, developer, python, local"
	assert_line --partial "release-here: Cut a release"
	assert_line --partial "servers: basedpyright"
	assert_output --partial "I release here."
}

@test "ls --json is the same listing as a structure" {
	fab ls --json
	assert_success
	run jq -r '.specialists.django | join(",")' <<<"$output"
	assert_output "python"
}

# ADR-050: the root of the tree is who works in a worktree, not a builder;
# the roles that write no code extend it and carry no builder's voice.
@test "architect, reviewer and manager extend committer and carry no test-first paragraph" {
	local s
	for s in architect reviewer manager; do
		fab show "$s"
		assert_success
		assert_line --partial "order: committer, $s"
		refute_output --partial "## developer"
		refute_output --partial "Test first."
	done
}

@test "show manager says it owns the policy, the guidance and the repository's catalogue, and assigns nothing" {
	fab show manager
	assert_success
	assert_line --partial "workflow-tuning:"
	assert_line --partial "task-splitting:"
	assert_output --partial "decider"
	assert_output --partial "factory-guidance.md"
	assert_output --partial "next machine build"
}
