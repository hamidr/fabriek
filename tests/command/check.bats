#!/usr/bin/env bats
# fabriek check <repo>: the declaration and every specialist a role names,
# resolved on the operator's host in seconds, at the commit fabriek up would
# read, and refused in plain words rather than minutes into a machine build.
# Evaluated for real over the shipped catalogue, no build.

load ../test_helper/common

setup() {
	setup_temp_dir
	export FABRIEK_SELF="$FABRIEK_ROOT"
	REPO="$TEST_TEMP_DIR/acme"
	mkdir -p "$REPO"
	git init -q "$REPO"
	git -C "$REPO" config user.name factory
	git -C "$REPO" config user.email factory@invalid
}

teardown() {
	teardown_temp_dir
}

## A repository declaring acme with the roles given, committed because that
## is what is read.
declare_roles() {
	cat >"$REPO/flake.nix" <<NIX
{
  outputs = { self }: {
    fabriek = {
      name = "acme";
      roles = { $1 };
      workflows.ship.stages = [ { needs = "build"; } ];
      $2
    };
  };
}
NIX
	git -C "$REPO" add -A
	git -C "$REPO" -c commit.gpgsign=false commit -qm declare
}

check() {
	run bash "$FABRIEK_ROOT/fabriek" check "$REPO"
}

@test "a sound declaration prints the commit it read and what each role is composed of" {
	declare_roles 'backend = { provides = [ "build" ]; specialists = [ "springboot" "python" ]; }; reviewer = { provides = [ "build" ]; };' ''
	check
	assert_success
	assert_line --index 0 --partial "acme at $(git -C "$REPO" rev-parse --short HEAD)"
	assert_line --partial "backend: committer, developer, java, springboot, python"
	assert_line --partial "reviewer: (no specialists)"
}

# ADR-053: replicas are expanded before anything reads the declaration, so
# check composes and names each replica, not the base.
@test "a role with replicas is checked as each replica, composed alike, and the base name is not a role" {
	declare_roles 'backend = { provides = [ "build" ]; specialists = [ "python" ]; replicas = 2; };' 'resources.concurrency = 2;'
	check
	assert_success
	assert_line --partial "backend-1: committer, developer, python"
	assert_line --partial "backend-2: committer, developer, python"
	refute_line --partial "  backend:"
}

@test "a specialist no catalogue has is refused in one plain line, naming the role and what is offered" {
	declare_roles 'backend = { provides = [ "build" ]; specialists = [ "rust" ]; };' ''
	check
	assert_failure
	assert_output --partial "role backend names specialist rust"
	assert_output --partial "offers: architect, committer, developer"
	refute_output --partial "while evaluating"
}

@test "a declaration the schema refuses is refused before any specialist is looked up" {
	declare_roles 'backend = { provides = [ "build" ]; colour = "blue"; };' ''
	check
	assert_failure
	assert_output --partial "colour"
}

@test "the repository's own catalogue is read at the commit, so an uncommitted specialist is not there yet" {
	mkdir -p "$REPO/fabriek/catalogue/specialists/local"
	printf 'I am local.\n' >"$REPO/fabriek/catalogue/specialists/local/PROMPT.md"
	printf '{ specialists, ... }: { extends = [ specialists.developer ]; prompt = ./PROMPT.md; }\n' >"$REPO/fabriek/catalogue/specialists/local/default.nix"
	declare_roles 'backend = { provides = [ "build" ]; specialists = [ "local" ]; };' 'catalogue = "fabriek/catalogue";'
	check
	assert_success
	assert_line --partial "backend: committer, developer, local"
	mkdir -p "$REPO/fabriek/catalogue/specialists/later"
	printf 'Later.\n' >"$REPO/fabriek/catalogue/specialists/later/PROMPT.md"
	printf '{ ... }: { prompt = ./PROMPT.md; }\n' >"$REPO/fabriek/catalogue/specialists/later/default.nix"
	sed -i.bak 's/"local"/"later"/' "$REPO/flake.nix" && rm "$REPO/flake.nix.bak"
	check
	assert_success
	assert_line --partial "backend: committer, developer, local"
	assert_output --partial "working tree differs"
}
