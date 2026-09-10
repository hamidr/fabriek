#!/usr/bin/env bats
# The one clone a factory works, which role worktrees are taken from (ADR-011).

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/names.sh
	source "$CAGEWORKS_ROOT/modules/names.sh"
	# shellcheck source=../../modules/factory-clone.sh
	source "$CAGEWORKS_ROOT/modules/factory-clone.sh"
	STATE="$TEST_TEMP_DIR/state"
}

teardown() {
	teardown_temp_dir
}

@test "a factory's clone lives in nixcage state, beside nothing the operator edits" {
	run cageworks_factory_clone_path "$STATE" acme
	assert_success
	assert_output "$STATE/factories/acme"
}

@test "two factories do not share a clone" {
	a="$(cageworks_factory_clone_path "$STATE" acme)"
	b="$(cageworks_factory_clone_path "$STATE" other)"
	[ "$a" != "$b" ]
}

@test "a factory name that could escape the state directory is refused" {
	run cageworks_factory_clone_path "$STATE" "../../etc"
	assert_failure
}

@test "the clone never shares object files with the repository it came from" {
	run cageworks_factory_clone_args /srv/acme "$STATE/factories/acme"
	assert_success
	assert_output --partial "--no-hardlinks"
	assert_output --partial "/srv/acme"
	assert_output --partial "$STATE/factories/acme"
}

@test "the clone's own tree sits on a branch no role could ever hold" {
	run cageworks_factory_clone_branch
	assert_success
	# A role's branches are always <role>/<leaf>, so a single segment cannot collide.
	refute_output --partial "/"
}

@test "main is not what the clone has checked out" {
	run cageworks_factory_clone_branch
	refute_output "main"
	refute_output "master"
}

@test "git is told a role's worktree is trustworthy, since the supervisor does not own it" {
	run cageworks_factory_git_args "$STATE/factories/acme"
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

	path="$(cageworks_factory_clone_ensure "$STATE" acme "$origin")"
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

	path="$(cageworks_factory_clone_ensure "$STATE" acme2 "$origin")"
	[ "$(git -C "$path" rev-parse --abbrev-ref HEAD)" != "$(cageworks_factory_shared_branch)" ]
}

@test "a repository may carry its own guidance for the roles working it" {
	repo="$TEST_TEMP_DIR/guided"
	mkdir -p "$repo/docs"
	printf 'in this factory, ADRs are immutable.\n' >"$repo/docs/factory-guidance.md"
	run cageworks_factory_guidance "$repo"
	assert_success
	assert_output --partial "ADRs are immutable"
}

@test "a repository that carries none is not an error" {
	repo="$TEST_TEMP_DIR/unguided"
	mkdir -p "$repo"
	run cageworks_factory_guidance "$repo"
	assert_success
	assert_output ""
}

@test "guidance is read from the factory's own clone, not from anywhere else" {
	run cageworks_factory_guidance_path "$STATE/factories/acme"
	assert_success
	assert_output "$STATE/factories/acme/docs/factory-guidance.md"
}

# A clone whose HEAD came back unborn -- an origin whose HEAD names a branch it
# does not have, an interrupted fetch -- used to leave a directory behind. The
# ensure skips a path that exists, so every later run reused it and failed with
# "no commit to read a declaration from", which says nothing about the clone and
# cannot be recovered from without somebody deleting the directory by hand.
@test "a clone that came back without a commit is not left behind to be reused" {
	local origin="$TEST_TEMP_DIR/origin.git"
	git init -q --bare "$origin"
	# Only refs/heads/main exists, and the bare repo's HEAD names another
	# branch, so git clone checks out nothing.
	local seed="$TEST_TEMP_DIR/seed"
	git init -q "$seed"
	git -C "$seed" config user.email t@invalid
	git -C "$seed" config user.name t
	touch "$seed/README.md"
	git -C "$seed" add -A
	git -C "$seed" -c commit.gpgsign=false commit -qm first
	git -C "$seed" push -q "$origin" HEAD:refs/heads/main
	git -C "$origin" symbolic-ref HEAD refs/heads/nowhere

	run cageworks_factory_clone_ensure "$STATE" acme "$origin"
	assert_failure
	assert_output --partial "no commit"

	# And nothing is left for the next run to trip over.
	[ ! -d "$STATE/factories/acme" ]
}
