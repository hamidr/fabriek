# shellcheck shell=bash
## Advancing the branch a factory shares with the operator, and stopping when
## their histories no longer agree (PRD-003 phase 6).
##
## Deciding what to merge is content and stays in a cage. Everything here reads
## nothing: it moves a ref to a named commit, or refuses. That is what lets the
## supervisor hold the one irreversible act while staying content-blind.
##
## Sourced by store path into cageworks-container alongside names.sh.

## Where the operator's current history is kept for comparison. A remote ref
## rather than a fetch into the branch itself, so looking never moves anything.
cageworks_integrate_mirror_ref() {
	echo "refs/cageworks/operator/$1"
}

## Have the two histories parted ways? Not "is one behind", which is ordinary,
## but "does neither contain the other", which only happens when something was
## rewritten under the factory's feet.
cageworks_integrate_diverged() {
	local clone="$1" repo="$2" branch="$3"
	local ref
	ref="$(cageworks_integrate_mirror_ref "$branch")"

	git -C "$clone" fetch -q "$repo" "+refs/heads/$branch:$ref" 2>/dev/null || return 1

	local ours theirs
	ours="$(git -C "$clone" rev-parse --verify --quiet "refs/heads/$branch")" || return 1
	theirs="$(git -C "$clone" rev-parse --verify --quiet "$ref")" || return 1

	git -C "$clone" merge-base --is-ancestor "$ours" "$theirs" && return 1
	git -C "$clone" merge-base --is-ancestor "$theirs" "$ours" && return 1
	return 0
}

cageworks_integrate_halt_file() {
	local state="$1" factory="$2"
	cageworks_name_ok "$factory" || return 1
	echo "$state/halted/$factory"
}

## Stop a factory and say why. Nothing is changed underneath anyone: no branch
## is rebased, no task discarded. The factory simply starts nothing more for
## this repository until someone says otherwise.
cageworks_integrate_halt() {
	local state="$1" factory="$2" reason="$3"
	local file
	file="$(cageworks_integrate_halt_file "$state" "$factory")" || return 1
	mkdir -p "$(dirname "$file")"
	printf '%s' "$reason" >"$file"
}

cageworks_integrate_halted() {
	local state="$1" factory="$2"
	local file
	file="$(cageworks_integrate_halt_file "$state" "$factory")" || return 1
	[ -f "$file" ] || return 1
	cat "$file"
}

## Resuming is a command rather than deleting state by hand, because a safe
## behaviour people can only undo by hand is one they learn to work around.
cageworks_integrate_resume() {
	local state="$1" factory="$2"
	local file
	file="$(cageworks_integrate_halt_file "$state" "$factory")" || return 1
	rm -f "$file"
}

## Move the shared branch to a commit that already contains it. Refused
## otherwise, which is what makes an unwanted merge recoverable: nothing the
## factory does can move that branch backwards or sideways.
cageworks_integrate_advance() {
	local clone="$1" branch="$2" commit="$3"
	local current
	current="$(git -C "$clone" rev-parse --verify --quiet "refs/heads/$branch")" || return 1

	if ! git -C "$clone" merge-base --is-ancestor "$current" "$commit"; then
		echo "cageworks: $commit does not fast-forward $branch" >&2
		return 1
	fi
	git -C "$clone" update-ref "refs/heads/$branch" "$commit" "$current"
}

## Hand what the factory advanced to the operator. A plain push, so it is
## refused rather than forced if their history moved: the factory never
## rewrites what the operator has.
cageworks_integrate_publish() {
	local clone="$1" repo="$2" branch="$3"
	git -C "$clone" push -q "$repo" "refs/heads/$branch:refs/heads/$branch"
}
