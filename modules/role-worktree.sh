# shellcheck shell=bash
## The worktree a factory role works in, and the parts of the repository's git
## directory its uid is granted (ADR-010, PRD-003).
##
## Sourced by store path into nixcage-container, alongside role-uid.sh, whose
## nixcage_role_name_ok this file relies on. A file rather than an inline
## string so shellcheck reads it and bats can source it.

## Role worktrees live in nixcage's own state rather than under a workspace
## root: they belong to the supervisor, and putting them beside the operator's
## projects would make them enterable by hand as if they were projects.
nixcage_role_worktree_path() {
	local state="$1" factory="$2" role="$3"
	nixcage_role_name_ok "$factory" || return 1
	nixcage_role_name_ok "$role" || return 1
	echo "$state/worktrees/$factory/$role"
}

## A role writes only refs under its own name, so every branch it takes is
## constructed here rather than anywhere a role's own string could reach.
## Phase 1 has no tasks, so the default is one working branch per role.
nixcage_role_branch() {
	local role="$1" leaf="${2:-work}"
	nixcage_role_name_ok "$role" || return 1
	nixcage_role_name_ok "$leaf" || return 1
	echo "$role/$leaf"
}

## The three directories a role's uid is granted, and no others. The git
## directory itself and packed-refs stay unreachable: packed-refs holds ref
## values, so a role able to write it could redefine main without ever
## touching refs/heads/main.
nixcage_role_acl_targets() {
	local gitdir="$1" role="$2"
	nixcage_role_name_ok "$role" || return 1
	echo "$gitdir/objects"
	echo "$gitdir/refs/heads/$role"
	echo "$gitdir/logs/refs/heads/$role"
}

## Create the role's worktree if it has none, hand it to the role's uid, and
## grant that uid the three parts of the repository it needs. Everything here
## is measured behaviour: chowning the tree and its administrative directory is
## what makes libgit2 open the repository, and the ACLs are what let a foreign
## uid write objects and its own refs with no shared group (ADR-010).
nixcage_role_worktree_ensure() {
	local state="$1" factory="$2" role="$3" repo="$4" uid="$5"

	local path branch gitdir target
	path="$(nixcage_role_worktree_path "$state" "$factory" "$role")" || return 1
	branch="$(nixcage_role_branch "$role")" || return 1

	gitdir="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)" || return 1

	if [ ! -d "$path" ]; then
		mkdir -p "$(dirname "$path")"
		if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
			git -C "$repo" worktree add --quiet "$path" "$branch" || return 1
		else
			git -C "$repo" worktree add --quiet -b "$branch" "$path" || return 1
		fi
	fi

	## The worktree and the administrative directory git keeps for it are the
	## two paths git and libgit2 check ownership of.
	chown -R "$uid:$uid" "$path" || return 1
	chown -R "$uid:$uid" "$gitdir/worktrees/$(basename "$path")" || return 1

	while IFS= read -r target; do
		[ -e "$target" ] || continue
		setfacl -R -m "u:$uid:rwX" -m "d:u:$uid:rwX" "$target" || return 1
	done < <(nixcage_role_acl_targets "$gitdir" "$role")

	echo "$path"
}
