# shellcheck shell=bash
## The worktree a factory role works in, and the parts of the repository's git
## directory its uid is granted (ADR-010, PRD-003).
##
## Sourced by store path into fabriek-container, alongside names.sh, whose
## fabriek_name_ok this file relies on. A file rather than an inline
## string so shellcheck reads it and bats can source it.

## Role worktrees live in the state nixcage keeps rather than under a workspace
## root: they belong to the supervisor, and putting them beside the operator's
## projects would make them enterable by hand as if they were projects.
fabriek_role_worktree_path() {
	local state="$1" factory="$2" role="$3"
	fabriek_name_ok "$factory" || return 1
	fabriek_name_ok "$role" || return 1
	echo "$state/worktrees/$factory/$role"
}

## A role writes only refs under its own name, so every branch it takes is
## constructed here rather than anywhere a role's own string could reach.
## Phase 1 has no tasks, so the default is one working branch per role.
fabriek_role_branch() {
	local role="$1" leaf="${2:-work}"
	fabriek_name_ok "$role" || return 1
	fabriek_name_ok "$leaf" || return 1
	echo "$role/$leaf"
}

## The three directories a role's uid is granted, and no others. The git
## directory itself and packed-refs stay unreachable: packed-refs holds ref
## values, so a role able to write it could redefine main without ever
## touching refs/heads/main.
fabriek_role_acl_targets() {
	local gitdir="$1" role="$2"
	fabriek_name_ok "$role" || return 1
	echo "$gitdir/objects"
	echo "$gitdir/refs/heads/$role"
	echo "$gitdir/logs/refs/heads/$role"
}

## Create the role's worktree if it has none, hand it to the role's uid, and
## grant that uid the three parts of the repository it needs. Everything here
## is measured behaviour: chowning the tree and its administrative directory is
## what makes libgit2 open the repository, and the ACLs are what let a foreign
## uid write objects and its own refs with no shared group (ADR-010).
fabriek_role_worktree_ensure() {
	local state="$1" factory="$2" role="$3" repo="$4" uid="$5"

	local path branch gitdir target
	path="$(fabriek_role_worktree_path "$state" "$factory" "$role")" || return 1
	branch="$(fabriek_role_branch "$role")" || return 1

	gitdir="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)" || return 1

	## The worktree is asked for rather than made, because what a role may
	## hold and whether an unclean stop can truncate its work are properties
	## of the filesystem underneath, which is nixcage's to know (ADR-017,
	## ADR-018). Asking may mount a dataset here, which is why the worktree is
	## recognised by its pointer rather than by the directory existing.
	nixcage-container storage ensure "$path" "$uid" >/dev/null || return 1

	if [ ! -e "$path/.git" ]; then
		mkdir -p "$(dirname "$path")"
		## A worktree the repository still has registered but that is no longer
		## on disk blocks the add outright. That is the state a role is left in
		## whenever its tree is removed from under it, and repairing it is what
		## this function is for.
		git -C "$repo" worktree prune
		if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
			git -C "$repo" worktree add --quiet "$path" "$branch" || return 1
		else
			git -C "$repo" worktree add --quiet -b "$branch" "$path" || return 1
		fi
	fi

	## A worktree can outlive its branch: an add that failed partway left
	## the pointer and no ref (seen when every role raced to clone), and the
	## role cannot make the ref itself. It gets the branch the add would
	## have given it, from the same place.
	if ! git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
		git -C "$repo" update-ref "refs/heads/$branch" HEAD "" || return 1
	fi

	## The index the role's codegraph tools read (ADR-049), built once here
	## while the tree is still the machine's, so the role's first session
	## finds it and no session pays for it again. Watching the tree for
	## changes is the daemon's job inside the cage; the machine program
	## starts none. An index that could not be built is said and not
	## fatal: the role still has its tree, and its status tool says the
	## graph is missing.
	if [ ! -d "$path/.codegraph" ]; then
		CODEGRAPH_NO_DAEMON=1 codegraph init -y "$path" >/dev/null 2>&1 ||
			echo "fabriek: codegraph could not index $path; the role works without the graph" >&2
	fi

	## The worktree and the administrative directory git keeps for it are the
	## two paths git and libgit2 check ownership of.
	chown -R "$uid:$uid" "$path" || return 1
	chown -R "$uid:$uid" "$gitdir/worktrees/$(basename "$path")" || return 1

	## Made rather than skipped when missing: git prunes a ref directory once
	## it is empty, and only root may make one again.
	while IFS= read -r target; do
		mkdir -p "$target" || return 1
		setfacl -R -m "u:$uid:rwX" -m "d:u:$uid:rwX" "$target" || return 1
	done < <(fabriek_role_acl_targets "$gitdir" "$role")

	echo "$path"
}
