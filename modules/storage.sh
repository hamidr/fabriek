# shellcheck shell=bash
## Datasets for the state nixcage keeps (ADR-017).
##
## A role's worktree is its own dataset where nixcage's state is on ZFS, which
## is what makes a per-role quota possible and what keeps an unclean shutdown
## from leaving a role's files truncated. Where it is not, every function here
## is a no-op and callers fall back to ordinary directories, because a Linux
## host's filesystem is the admin's choice and not nixcage's.
##
## Sourced by store path into nixcage-container beside role-worktree.sh.

## The dataset a role's worktree lives on. Mirrors the directory layout
## exactly, so a dataset name can always be read off a path and back.
nixcage_storage_worktree_dataset() {
	local root="$1" factory="$2" role="$3"
	[ -n "$root" ] || return 1
	nixcage_role_name_ok "$factory" || return 1
	nixcage_role_name_ok "$role" || return 1
	echo "$root/worktrees/$factory/$role"
}

## Answer whether a dataset exists.
nixcage_storage_has_dataset() {
	zfs list -H -o name "$1" >/dev/null 2>&1
}

## Create a dataset that exists only to hold others, mounted nowhere.
##
## Not cosmetic: a mounted parent would cover the directory it mounts on, and
## that directory holds the worktrees of every other role of the factory. An
## unmounted container has no mountpoint to cover anything with.
nixcage_storage_ensure_container() {
	local dataset="$1"
	nixcage_storage_has_dataset "$dataset" && return 0
	zfs create -o mountpoint=none "$dataset"
}

## Create the dataset a role's worktree lives on, and apply the declared quota
## whether the dataset is new or not: a quota that only took effect on creation
## would leave every role declared before it unbounded.
##
## refquota rather than quota: it bounds what the role itself writes, and does
## not count snapshots taken of its work against it.
nixcage_storage_ensure_worktree() {
	local root="$1" factory="$2" role="$3" mountpoint="$4" quota="${5:-}"
	[ -n "$root" ] || return 0

	local dataset
	dataset="$(nixcage_storage_worktree_dataset "$root" "$factory" "$role")" || return 1

	if ! nixcage_storage_has_dataset "$dataset"; then
		## A worktree that predates the pool -- migrated off the old volume,
		## or made before the machine had a dataset to give it -- keeps its
		## directory. Mounting over it would hide the role's work while
		## leaving something that looks like an empty worktree in its place.
		if [ -d "$mountpoint" ] && [ -n "$(ls -A "$mountpoint")" ]; then
			echo "nixcage: $mountpoint already holds a worktree; leaving it a directory rather than mounting a dataset over it" >&2
			return 0
		fi
		nixcage_storage_ensure_container "$root/worktrees" || return 1
		nixcage_storage_ensure_container "$root/worktrees/$factory" || return 1
		zfs create -o "mountpoint=$mountpoint" "$dataset" || return 1
	fi

	## Cleared when the declaration no longer names one, so the declaration
	## stays the whole truth about a role's bound.
	zfs set "refquota=${quota:-none}" "$dataset" || return 1
}
