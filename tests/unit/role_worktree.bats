#!/usr/bin/env bats
# A role's worktree: where it lives, what branch it holds, and which
# directories carry its ACL (ADR-010, PRD-003).

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/names.sh
	source "$FABRIEK_ROOT/modules/names.sh"
	# shellcheck source=../../modules/role-worktree.sh
	source "$FABRIEK_ROOT/modules/role-worktree.sh"
	STATE="$TEST_TEMP_DIR/state"
	STUB_DIR="$TEST_TEMP_DIR/bin"
	mkdir -p "$STUB_DIR"
	PATH="$STUB_DIR:$PATH"
	export PATH
}

teardown() {
	teardown_temp_dir
}

@test "a role's worktree lives in nixcage state, not beside the operator's projects" {
	run fabriek_role_worktree_path "$STATE" acme builder
	assert_success
	assert_output "$STATE/worktrees/acme/builder"
}

@test "the same role always resolves to the same worktree" {
	a="$(fabriek_role_worktree_path "$STATE" acme builder)"
	b="$(fabriek_role_worktree_path "$STATE" acme builder)"
	[ "$a" = "$b" ]
}

@test "two factories can hold a role of the same name without colliding" {
	a="$(fabriek_role_worktree_path "$STATE" acme builder)"
	b="$(fabriek_role_worktree_path "$STATE" other builder)"
	[ "$a" != "$b" ]
}

@test "a name that could escape the state directory is refused" {
	run fabriek_role_worktree_path "$STATE" acme "../../etc"
	assert_failure
	run fabriek_role_worktree_path "$STATE" "../../etc" builder
	assert_failure
}

@test "a role's branch sits inside the role's own namespace" {
	run fabriek_role_branch builder task-0041
	assert_success
	assert_output "builder/task-0041"
}

@test "a branch outside the role's namespace cannot be constructed" {
	run fabriek_role_branch builder "../main"
	assert_failure
	run fabriek_role_branch "../evil" task-0041
	assert_failure
}

@test "phase 1 has no tasks, so a role gets a working branch of its own" {
	run fabriek_role_branch builder
	assert_success
	assert_output "builder/work"
}

@test "exactly three directories carry a role's ACL" {
	run fabriek_role_acl_targets /repo/.git builder
	assert_success
	assert_line --index 0 "/repo/.git/objects"
	assert_line --index 1 "/repo/.git/refs/heads/builder"
	assert_line --index 2 "/repo/.git/logs/refs/heads/builder"
	[ "${#lines[@]}" -eq 3 ]
}

@test "the ACL never reaches packed-refs or the git directory itself" {
	run fabriek_role_acl_targets /repo/.git builder
	refute_output --partial "packed-refs"
	for line in "${lines[@]}"; do
		[ "$line" != "/repo/.git" ]
	done
}

@test "an invalid role cannot be given an ACL" {
	run fabriek_role_acl_targets /repo/.git "../../.."
	assert_failure
}

# chown and setfacl need root, and the storage a worktree sits on is nixcage's
# to give. Neither is what these tests are about: the worktree is.
#
# The storage stub makes the directory, which is what a real dataset creation
# does, and records the argv it was asked with -- the seam is the assertion.
stub_privileged_tools() {
	local tool
	for tool in chown setfacl; do
		printf '#!/usr/bin/env bash\nexit 0\n' >"$STUB_DIR/$tool"
		chmod +x "$STUB_DIR/$tool"
	done
	cat >"$STUB_DIR/nixcage-container" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TEST_TEMP_DIR/nixcage-calls"
if [ "\$1" = storage ]; then
	mkdir -p "\$3"
	echo "\$3"
fi
EOF
	chmod +x "$STUB_DIR/nixcage-container"
}

storage_calls() {
	cat "$TEST_TEMP_DIR/nixcage-calls" 2>/dev/null
}

make_repo() {
	local repo="$TEST_TEMP_DIR/repo"
	mkdir -p "$repo"
	git -C "$repo" init -q -b main
	git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m first
	echo "$repo"
}

@test "a worktree is asked for by path and by uid, never as a dataset" {
	# Whether the path becomes a dataset or an ordinary directory is nixcage's
	# decision, and fabriek is not told which it got (ADR-018).
	stub_privileged_tools
	repo="$(make_repo)"
	run fabriek_role_worktree_ensure "$STATE" acme builder "$repo" 700000
	assert_success
	run storage_calls
	assert_output "storage ensure $STATE/worktrees/acme/builder 700000 "
	refute_output --partial "zfs"
	refute_output --partial "dataset"
}

@test "a declared quota is what the worktree is asked to be bounded by" {
	stub_privileged_tools
	repo="$(make_repo)"
	run fabriek_role_worktree_ensure "$STATE" acme builder "$repo" 700000 20G
	assert_success
	run storage_calls
	assert_output "storage ensure $STATE/worktrees/acme/builder 700000 20G"
}

@test "a worktree nixcage could not give is not worked around" {
	# A role whose storage failed has nowhere to write; carrying on would put
	# its work somewhere nobody bounded.
	stub_privileged_tools
	printf '#!/usr/bin/env bash\nexit 1\n' >"$STUB_DIR/nixcage-container"
	chmod +x "$STUB_DIR/nixcage-container"
	repo="$(make_repo)"
	run fabriek_role_worktree_ensure "$STATE" acme builder "$repo" 700000
	assert_failure
	[ ! -e "$STATE/worktrees/acme/builder/.git" ]
}

@test "the worktree is added into the empty directory it was given" {
	# Asking for storage makes the directory exist, so a worktree recognised
	# by its directory rather than by its own pointer would never be added.
	stub_privileged_tools
	repo="$(make_repo)"
	run fabriek_role_worktree_ensure "$STATE" acme builder "$repo" 0
	assert_success
	[ -e "$STATE/worktrees/acme/builder/.git" ]
}

@test "a role entered twice keeps the one worktree it has" {
	stub_privileged_tools
	repo="$(make_repo)"
	fabriek_role_worktree_ensure "$STATE" acme builder "$repo" 0
	run fabriek_role_worktree_ensure "$STATE" acme builder "$repo" 0
	assert_success
	[ "$(git -C "$repo" worktree list | wc -l)" -eq 2 ]
}

@test "a role whose worktree was removed gets it back" {
	# Removing the tree leaves the repository still holding a registration
	# for it, which blocks the add until it is pruned.
	stub_privileged_tools
	repo="$(make_repo)"
	fabriek_role_worktree_ensure "$STATE" acme builder "$repo" 0
	rm -rf "$STATE/worktrees/acme/builder"
	run fabriek_role_worktree_ensure "$STATE" acme builder "$repo" 0
	assert_success
	[ -e "$STATE/worktrees/acme/builder/.git" ]
}
