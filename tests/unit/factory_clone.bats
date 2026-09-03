#!/usr/bin/env bats
# The one clone a factory works, which role worktrees are taken from (ADR-011).

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/role-uid.sh
	source "$NIXCAGE_ROOT/modules/role-uid.sh"
	# shellcheck source=../../modules/factory-clone.sh
	source "$NIXCAGE_ROOT/modules/factory-clone.sh"
	STATE="$TEST_TEMP_DIR/state"
}

teardown() {
	teardown_temp_dir
}

@test "a factory's clone lives in nixcage state, beside nothing the operator edits" {
	run nixcage_factory_clone_path "$STATE" acme
	assert_success
	assert_output "$STATE/factories/acme"
}

@test "two factories do not share a clone" {
	a="$(nixcage_factory_clone_path "$STATE" acme)"
	b="$(nixcage_factory_clone_path "$STATE" other)"
	[ "$a" != "$b" ]
}

@test "a factory name that could escape the state directory is refused" {
	run nixcage_factory_clone_path "$STATE" "../../etc"
	assert_failure
}

@test "the clone never shares object files with the repository it came from" {
	run nixcage_factory_clone_args /srv/acme "$STATE/factories/acme"
	assert_success
	assert_output --partial "--no-hardlinks"
	assert_output --partial "/srv/acme"
	assert_output --partial "$STATE/factories/acme"
}

@test "the clone's own tree sits on a branch no role could ever hold" {
	run nixcage_factory_clone_branch
	assert_success
	# A role's branches are always <role>/<leaf>, so a single segment cannot collide.
	refute_output --partial "/"
}

@test "main is not what the clone has checked out" {
	run nixcage_factory_clone_branch
	refute_output "main"
	refute_output "master"
}

@test "git is told a role's worktree is trustworthy, since the supervisor does not own it" {
	run nixcage_factory_git_args "$STATE/factories/acme"
	assert_success
	assert_output --partial "safe.directory=$STATE/factories/acme"
}

@test "the clone has the shared branch locally, since the operator checks it out nowhere" {
	origin="$TEST_TEMP_DIR/origin"
	git init -q -b main "$origin"
	git -C "$origin" config user.name o
	git -C "$origin" config user.email o@x
	git -C "$origin" config commit.gpgsign false
	echo x >"$origin/a.txt"
	git -C "$origin" add a.txt
	git -C "$origin" commit -qm one
	# main checked out by nothing, exactly as the design requires.
	git -C "$origin" switch -q -c operator/work

	path="$(nixcage_factory_clone_ensure "$STATE" acme "$origin")"
	run git -C "$path" rev-parse --verify refs/heads/main
	assert_success
}

@test "the clone's own tree is not on the branch it integrates" {
	origin="$TEST_TEMP_DIR/origin2"
	git init -q -b main "$origin"
	git -C "$origin" config user.name o
	git -C "$origin" config user.email o@x
	git -C "$origin" config commit.gpgsign false
	echo x >"$origin/a.txt"
	git -C "$origin" add a.txt
	git -C "$origin" commit -qm one
	git -C "$origin" switch -q -c operator/work

	path="$(nixcage_factory_clone_ensure "$STATE" acme2 "$origin")"
	[ "$(git -C "$path" rev-parse --abbrev-ref HEAD)" != "$(nixcage_factory_shared_branch)" ]
}
