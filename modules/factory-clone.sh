# shellcheck shell=bash
## The one clone a factory works (ADR-011).
##
## Roles take worktrees of this clone rather than of the operator's checkout,
## because role ownership needs a filesystem carrying ownership and ACLs and
## the operator's may not have one. The supervisor syncs the two. Sourced by
## store path into fabriek-container alongside names.sh, whose
## fabriek_name_ok this file relies on.

## The clone lives in the state nixcage keeps. It is the supervisor's working
## copy, not something the operator edits: everything reaching it arrives by a
## fetch and everything leaving it leaves by a push.
fabriek_factory_clone_path() {
	local state="$1" factory="$2"
	fabriek_name_ok "$factory" || return 1
	echo "$state/factories/$factory"
}

## A role's branches are always <role>/<leaf>, so a single-segment name cannot
## collide with any role's namespace however the roles are declared. It is also
## not the branch the factory integrates, which stays checked out by nothing so
## that advancing it is a ref update.
fabriek_factory_clone_branch() {
	echo "supervisor"
}

## The branch the factory integrates into and shares with the operator. Named
## here rather than assumed at every call site.
fabriek_factory_shared_branch() {
	echo "main"
}

## The source is a remote the machine can reach rather than a path on the
## operator's host (ADR-032), so git has nothing local to hardlink from and
## --no-hardlinks costs nothing. It stays because it is free and because the
## day somebody points a factory at a path on the machine itself, hardlinked
## objects and a chown would rewrite that repository's ownership.
fabriek_factory_clone_args() {
	local repo="$1" path="$2"
	echo "--no-hardlinks"
	echo "$repo"
	echo "$path"
}

## A role's worktree belongs to the role, and the supervisor is root, so git
## refuses to touch it until it is named as trustworthy. Without this the
## failure reads as "detected dubious ownership" rather than as a permission
## problem.
fabriek_factory_git_args() {
	local path="$1"
	echo "-c"
	echo "safe.directory=$path"
}

## Create the factory's clone if it has none, and leave its own tree on a
## branch no role holds. Idempotent: an existing clone is left alone, since it
## carries work the supervisor has not pushed yet.
fabriek_factory_clone_ensure() {
	local state="$1" factory="$2" repo="$3"

	local path branch
	path="$(fabriek_factory_clone_path "$state" "$factory")" || return 1
	branch="$(fabriek_factory_clone_branch)"

	if [ ! -d "$path" ]; then
		mkdir -p "$(dirname "$path")"
		local -a args=()
		local arg
		while IFS= read -r arg; do
			args+=("$arg")
		done < <(fabriek_factory_clone_args "$repo" "$path")
		git clone --quiet "${args[@]}" || return 1

		## A clone can succeed and check out nothing: an origin whose HEAD
		## names a branch it does not have leaves HEAD unborn, and so does an
		## origin with no commits at all. Branching from that gives an unborn
		## branch, and every later run skips the clone because the directory is
		## there and fails on a missing HEAD instead. The directory goes with
		## the failure so the next run is a first run.
		if ! git -C "$path" rev-parse --verify --quiet HEAD >/dev/null; then
			rm -rf "$path"
			echo "fabriek: $repo cloned with no commit on HEAD; nothing to work from" >&2
			return 1
		fi

		git -C "$path" switch --quiet -c "$branch" || return 1

		## The branch the factory integrates is checked out by nothing in the
		## operator's repository, so cloning leaves it as a remote ref only.
		## It has to exist locally here or there is nothing to advance.
		local shared
		shared="$(fabriek_factory_shared_branch)"
		if ! git -C "$path" rev-parse --verify --quiet "refs/heads/$shared" >/dev/null &&
			git -C "$path" rev-parse --verify --quiet "refs/remotes/origin/$shared" >/dev/null; then
			git -C "$path" branch --quiet "$shared" "origin/$shared" || return 1
		fi
	fi

	echo "$path"
}
