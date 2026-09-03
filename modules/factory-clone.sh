# shellcheck shell=bash
## The one clone a factory works (ADR-011).
##
## Roles take worktrees of this clone rather than of the operator's checkout,
## because role ownership needs a filesystem carrying ownership and ACLs and
## the operator's may not have one. The supervisor syncs the two. Sourced by
## store path into nixcage-container alongside role-uid.sh, whose
## nixcage_role_name_ok this file relies on.

## The clone lives in nixcage's own state. It is the supervisor's working copy,
## not something the operator edits: everything reaching it arrives by fetch and
## everything leaving it leaves by push.
nixcage_factory_clone_path() {
	local state="$1" factory="$2"
	nixcage_role_name_ok "$factory" || return 1
	echo "$state/factories/$factory"
}

## A role's branches are always <role>/<leaf>, so a single-segment name cannot
## collide with any role's namespace however the roles are declared. It is also
## not the branch the factory integrates, which stays checked out by nothing so
## that advancing it is a ref update.
nixcage_factory_clone_branch() {
	echo "supervisor"
}

## The branch the factory integrates into and shares with the operator. Named
## here rather than assumed at every call site.
nixcage_factory_shared_branch() {
	echo "main"
}

## --no-hardlinks is load-bearing here for the same reason it is anywhere else:
## git hardlinks objects when cloning from a local path on the same filesystem,
## and chowning anything derived from such a clone rewrites the origin's
## ownership. On Linux the origin is the operator's own repository.
nixcage_factory_clone_args() {
	local repo="$1" path="$2"
	echo "--no-hardlinks"
	echo "$repo"
	echo "$path"
}

## A role's worktree belongs to the role, and the supervisor is root, so git
## refuses to touch it until it is named as trustworthy. Without this the
## failure reads as "detected dubious ownership" rather than as a permission
## problem.
nixcage_factory_git_args() {
	local path="$1"
	echo "-c"
	echo "safe.directory=$path"
}

## Create the factory's clone if it has none, and leave its own tree on a
## branch no role holds. Idempotent: an existing clone is left alone, since it
## carries work the supervisor has not pushed yet.
nixcage_factory_clone_ensure() {
	local state="$1" factory="$2" repo="$3"

	local path branch
	path="$(nixcage_factory_clone_path "$state" "$factory")" || return 1
	branch="$(nixcage_factory_clone_branch)"

	if [ ! -d "$path" ]; then
		mkdir -p "$(dirname "$path")"
		local -a args=()
		local arg
		while IFS= read -r arg; do
			args+=("$arg")
		done < <(nixcage_factory_clone_args "$repo" "$path")
		git clone --quiet "${args[@]}" || return 1
		git -C "$path" switch --quiet -c "$branch" || return 1

		## The branch the factory integrates is checked out by nothing in the
		## operator's repository, so cloning leaves it as a remote ref only.
		## It has to exist locally here or there is nothing to advance.
		local shared
		shared="$(nixcage_factory_shared_branch)"
		if ! git -C "$path" rev-parse --verify --quiet "refs/heads/$shared" >/dev/null &&
			git -C "$path" rev-parse --verify --quiet "refs/remotes/origin/$shared" >/dev/null; then
			git -C "$path" branch --quiet "$shared" "origin/$shared" || return 1
		fi
	fi

	echo "$path"
}

## Where a repository keeps the guidance for roles working it. The baseline
## nixcage ships states properties of the cage; this states the conventions of
## this factory, which are the architect's to maintain and the operator's to
## accept, like any other document in that repository.
nixcage_factory_guidance_path() {
	echo "$1/docs/factory-guidance.md"
}

nixcage_factory_guidance() {
	local repo="$1" file
	file="$(nixcage_factory_guidance_path "$repo")"
	[ -f "$file" ] || return 0
	cat "$file"
}
