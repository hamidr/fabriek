#!/usr/bin/env bats
# A role's worktree is a dataset of its own where nixcage's state is on ZFS,
# so it can be bounded and cannot be truncated by an unclean shutdown.

load ../test_helper/common

setup() {
	setup_temp_dir
	STUB_DIR="$TEST_TEMP_DIR/bin"
	mkdir -p "$STUB_DIR"
	PATH="$STUB_DIR:$PATH"
	export PATH
	# shellcheck source=../../modules/role-uid.sh
	source "$NIXCAGE_ROOT/modules/role-uid.sh"
	# shellcheck source=../../modules/storage.sh
	source "$NIXCAGE_ROOT/modules/storage.sh"
	stub_zfs
}

teardown() {
	teardown_temp_dir
}

# Stand in for zfs: logs every call, and reports a dataset as existing only
# once 'create' has been seen for it.
stub_zfs() {
	cat >"$STUB_DIR/zfs" <<EOF
#!/usr/bin/env bash
printf '%s\n' "zfs \$*" >>"$TEST_TEMP_DIR/calls"
case "\$1" in
list)
	grep -qx "\${*: -1}" "$TEST_TEMP_DIR/datasets" 2>/dev/null || exit 1
	;;
create)
	printf '%s\n' "\${*: -1}" >>"$TEST_TEMP_DIR/datasets"
	;;
esac
exit 0
EOF
	chmod +x "$STUB_DIR/zfs"
}

@test "a role's dataset mirrors the path its worktree has" {
	run nixcage_storage_worktree_dataset nixcage/state acme builder
	assert_success
	assert_output "nixcage/state/worktrees/acme/builder"
}

@test "a role name that could escape the dataset tree is refused" {
	run nixcage_storage_worktree_dataset nixcage/state acme "../../tank"
	assert_failure
}

@test "with no dataset configured there is nothing to name" {
	run nixcage_storage_worktree_dataset "" acme builder
	assert_failure
}

@test "the dataset is created at the mountpoint the worktree uses" {
	run nixcage_storage_ensure_worktree nixcage/state acme builder "$TEST_TEMP_DIR/wt"
	assert_success
	run cat "$TEST_TEMP_DIR/calls"
	assert_output --partial "zfs create -o mountpoint=$TEST_TEMP_DIR/wt nixcage/state/worktrees/acme/builder"
}

@test "the datasets above a role hold others and are mounted nowhere" {
	# A mounted parent covers the directory it mounts on, and that directory
	# holds every other role's worktree.
	run nixcage_storage_ensure_worktree nixcage/state acme builder "$TEST_TEMP_DIR/wt"
	assert_success
	run cat "$TEST_TEMP_DIR/calls"
	assert_output --partial "zfs create -o mountpoint=none nixcage/state/worktrees"
	assert_output --partial "zfs create -o mountpoint=none nixcage/state/worktrees/acme"
}

@test "a worktree that predates the pool keeps its directory" {
	# Mounting a fresh dataset over it would hide the role's work and leave
	# something that looks like an empty worktree in its place.
	mkdir -p "$TEST_TEMP_DIR/wt"
	echo existing >"$TEST_TEMP_DIR/wt/file"
	run nixcage_storage_ensure_worktree nixcage/state acme builder "$TEST_TEMP_DIR/wt"
	assert_success
	assert_output --partial "already holds a worktree"
	run cat "$TEST_TEMP_DIR/calls"
	refute_output --partial "zfs create"
}

@test "a dataset that is already there is not created again" {
	nixcage_storage_ensure_worktree nixcage/state acme builder "$TEST_TEMP_DIR/wt"
	: >"$TEST_TEMP_DIR/calls"
	run nixcage_storage_ensure_worktree nixcage/state acme builder "$TEST_TEMP_DIR/wt"
	assert_success
	run cat "$TEST_TEMP_DIR/calls"
	refute_output --partial "zfs create"
}

@test "a declared quota is applied to a role that already exists" {
	nixcage_storage_ensure_worktree nixcage/state acme builder "$TEST_TEMP_DIR/wt"
	: >"$TEST_TEMP_DIR/calls"
	run nixcage_storage_ensure_worktree nixcage/state acme builder "$TEST_TEMP_DIR/wt" 20G
	assert_success
	run cat "$TEST_TEMP_DIR/calls"
	assert_output --partial "zfs set refquota=20G nixcage/state/worktrees/acme/builder"
}

@test "a quota the declaration drops is cleared, not left behind" {
	nixcage_storage_ensure_worktree nixcage/state acme builder "$TEST_TEMP_DIR/wt" 20G
	: >"$TEST_TEMP_DIR/calls"
	run nixcage_storage_ensure_worktree nixcage/state acme builder "$TEST_TEMP_DIR/wt"
	assert_success
	run cat "$TEST_TEMP_DIR/calls"
	assert_output --partial "zfs set refquota=none"
}

@test "no dataset configured means zfs is never called" {
	run nixcage_storage_ensure_worktree "" acme builder /wt 20G
	assert_success
	[ ! -s "$TEST_TEMP_DIR/calls" ]
}
