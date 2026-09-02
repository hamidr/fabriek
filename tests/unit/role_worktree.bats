#!/usr/bin/env bats
# A role's worktree: where it lives, what branch it holds, and which
# directories carry its ACL (ADR-010, PRD-003).

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/role-uid.sh
	source "$NIXCAGE_ROOT/modules/role-uid.sh"
	# shellcheck source=../../modules/role-worktree.sh
	source "$NIXCAGE_ROOT/modules/role-worktree.sh"
	STATE="$TEST_TEMP_DIR/state"
}

teardown() {
	teardown_temp_dir
}

@test "a role's worktree lives in nixcage state, not beside the operator's projects" {
	run nixcage_role_worktree_path "$STATE" acme builder
	assert_success
	assert_output "$STATE/worktrees/acme/builder"
}

@test "the same role always resolves to the same worktree" {
	a="$(nixcage_role_worktree_path "$STATE" acme builder)"
	b="$(nixcage_role_worktree_path "$STATE" acme builder)"
	[ "$a" = "$b" ]
}

@test "two factories can hold a role of the same name without colliding" {
	a="$(nixcage_role_worktree_path "$STATE" acme builder)"
	b="$(nixcage_role_worktree_path "$STATE" other builder)"
	[ "$a" != "$b" ]
}

@test "a name that could escape the state directory is refused" {
	run nixcage_role_worktree_path "$STATE" acme "../../etc"
	assert_failure
	run nixcage_role_worktree_path "$STATE" "../../etc" builder
	assert_failure
}

@test "a role's branch sits inside the role's own namespace" {
	run nixcage_role_branch builder task-0041
	assert_success
	assert_output "builder/task-0041"
}

@test "a branch outside the role's namespace cannot be constructed" {
	run nixcage_role_branch builder "../main"
	assert_failure
	run nixcage_role_branch "../evil" task-0041
	assert_failure
}

@test "phase 1 has no tasks, so a role gets a working branch of its own" {
	run nixcage_role_branch builder
	assert_success
	assert_output "builder/work"
}

@test "exactly three directories carry a role's ACL" {
	run nixcage_role_acl_targets /repo/.git builder
	assert_success
	assert_line --index 0 "/repo/.git/objects"
	assert_line --index 1 "/repo/.git/refs/heads/builder"
	assert_line --index 2 "/repo/.git/logs/refs/heads/builder"
	[ "${#lines[@]}" -eq 3 ]
}

@test "the ACL never reaches packed-refs or the git directory itself" {
	run nixcage_role_acl_targets /repo/.git builder
	refute_output --partial "packed-refs"
	for line in "${lines[@]}"; do
		[ "$line" != "/repo/.git" ]
	done
}

@test "an invalid role cannot be given an ACL" {
	run nixcage_role_acl_targets /repo/.git "../../.."
	assert_failure
}
