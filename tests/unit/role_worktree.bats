#!/usr/bin/env bats
# A role's worktree: where it lives, what branch it holds, and which
# directories carry its ACL (ADR-010, PRD-003).

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/role-uid.sh
	source "$NIXCAGE_ROOT/modules/role-uid.sh"
	# shellcheck source=../../modules/storage.sh
	source "$NIXCAGE_ROOT/modules/storage.sh"
	# shellcheck source=../../modules/role-worktree.sh
	source "$NIXCAGE_ROOT/modules/role-worktree.sh"
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

# chown and setfacl need root, and a dataset needs ZFS. Neither is what these
# tests are about: the worktree is.
stub_privileged_tools() {
	local tool
	for tool in chown setfacl; do
		printf '#!/usr/bin/env bash\nexit 0\n' >"$STUB_DIR/$tool"
		chmod +x "$STUB_DIR/$tool"
	done
	cat >"$STUB_DIR/zfs" <<EOF
#!/usr/bin/env bash
printf '%s\n' "zfs \$*" >>"$TEST_TEMP_DIR/zfs-calls"
case "\$1" in
list) grep -qx "\${*: -1}" "$TEST_TEMP_DIR/datasets" 2>/dev/null || exit 1 ;;
create)
	printf '%s\n' "\${*: -1}" >>"$TEST_TEMP_DIR/datasets"
	## A real create mounts the dataset, which is the state the worktree has
	## to cope with: the directory is there and empty.
	for arg in "\$@"; do
		case "\$arg" in mountpoint=*) mkdir -p "\${arg#mountpoint=}" ;; esac
	done
	;;
esac
exit 0
EOF
	chmod +x "$STUB_DIR/zfs"
}

make_repo() {
	local repo="$TEST_TEMP_DIR/repo"
	mkdir -p "$repo"
	git -C "$repo" init -q -b main
	git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m first
	echo "$repo"
}

@test "a role with no dataset configured still gets its worktree" {
	stub_privileged_tools
	repo="$(make_repo)"
	run nixcage_role_worktree_ensure "$STATE" acme builder "$repo" 0
	assert_success
	[ -e "$STATE/worktrees/acme/builder/.git" ]
	[ ! -s "$TEST_TEMP_DIR/zfs-calls" ]
}

@test "a role's worktree is a dataset mounted where the worktree goes" {
	stub_privileged_tools
	repo="$(make_repo)"
	run nixcage_role_worktree_ensure "$STATE" acme builder "$repo" 0 nixcage/state 20G
	assert_success
	run cat "$TEST_TEMP_DIR/zfs-calls"
	assert_output --partial "mountpoint=$STATE/worktrees/acme/builder nixcage/state/worktrees/acme/builder"
	assert_output --partial "zfs set refquota=20G"
}

@test "the worktree is added into the empty directory the dataset mounts" {
	# Creating the dataset makes the directory exist, so a worktree recognised
	# by its directory rather than by its own pointer would never be added.
	stub_privileged_tools
	repo="$(make_repo)"
	run nixcage_role_worktree_ensure "$STATE" acme builder "$repo" 0 nixcage/state
	assert_success
	[ -e "$STATE/worktrees/acme/builder/.git" ]
}

@test "a role entered twice keeps the one worktree it has" {
	stub_privileged_tools
	repo="$(make_repo)"
	nixcage_role_worktree_ensure "$STATE" acme builder "$repo" 0 nixcage/state
	run nixcage_role_worktree_ensure "$STATE" acme builder "$repo" 0 nixcage/state
	assert_success
	[ "$(git -C "$repo" worktree list | wc -l)" -eq 2 ]
}

@test "a role whose worktree was removed gets it back" {
	# Removing the tree leaves the repository still holding a registration
	# for it, which blocks the add until it is pruned.
	stub_privileged_tools
	repo="$(make_repo)"
	nixcage_role_worktree_ensure "$STATE" acme builder "$repo" 0
	rm -rf "$STATE/worktrees/acme/builder"
	run nixcage_role_worktree_ensure "$STATE" acme builder "$repo" 0
	assert_success
	[ -e "$STATE/worktrees/acme/builder/.git" ]
}
