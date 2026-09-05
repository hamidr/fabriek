# shellcheck shell=bash
## The caps that stop a factory (PRD-003 phase 5).
##
## Two kinds. Concurrency is global to the machine: it bounds how many agent
## sessions run at once regardless of how many workflows want to, because the
## machine is the thing that runs out. Budget is per workflow: exhausting one
## stops that workflow and leaves the others alone, so one runaway does not
## take the factory with it.
##
## Both are files rather than a counter in memory, because the supervisor is
## not a daemon: a run may outlive the invocation that started it, and a cap
## nobody can read after a crash is not a cap.
##
## Sourced by store path into cageworks-container alongside names.sh.

cageworks_cap_active_dir() {
	echo "$1/active"
}

## How many runs are in flight, machine-wide.
cageworks_cap_active() {
	local root="$1" dir
	dir="$(cageworks_cap_active_dir "$root")"
	[ -d "$dir" ] || {
		echo 0
		return 0
	}
	local n=0 path
	for path in "$dir"/*; do
		[ -e "$path" ] && n=$((n + 1))
	done
	echo "$n"
}

## Take a slot, or refuse. Claiming a run that already holds one is not a
## second claim: a retry of the same run is the same run.
cageworks_cap_claim() {
	local root="$1" factory="$2" id="$3" max="$4"
	cageworks_name_ok "$factory" || return 1
	[[ "$id" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || return 1

	local dir marker
	dir="$(cageworks_cap_active_dir "$root")"
	marker="$dir/$factory-$id"
	mkdir -p "$dir"
	[ -e "$marker" ] && return 0

	local active
	active="$(cageworks_cap_active "$root")"
	if [ "$max" -gt 0 ] && [ "$active" -ge "$max" ]; then
		echo "cageworks: $active runs already in flight, and the machine allows $max" >&2
		return 1
	fi
	: >"$marker"
}

cageworks_cap_release() {
	local root="$1" factory="$2" id="$3"
	cageworks_name_ok "$factory" || return 1
	rm -f "$(cageworks_cap_active_dir "$root")/$factory-$id"
}

cageworks_cap_spent() {
	local root="$1" factory="$2" workflow="$3" kind="$4"
	cageworks_name_ok "$factory" || return 1
	cageworks_name_ok "$workflow" || return 1
	cageworks_name_ok "$kind" || return 1
	local file="$root/budget/$factory/$workflow/$kind"
	if [ -f "$file" ]; then
		cat "$file"
	else
		echo 0
	fi
}

## Charge a workflow. An allowance of zero is unbounded rather than forbidden:
## a workflow that declares no budget is one nobody has bounded yet, not one
## that may not run.
cageworks_cap_spend() {
	local root="$1" factory="$2" workflow="$3" kind="$4" amount="$5" max="$6"
	local spent
	spent="$(cageworks_cap_spent "$root" "$factory" "$workflow" "$kind")" || return 1

	local after=$((spent + amount))
	if [ "$max" -gt 0 ] && [ "$after" -gt "$max" ]; then
		echo "cageworks: $workflow has spent $spent of $max $kind, and this run needs $amount" >&2
		return 1
	fi

	local dir="$root/budget/$factory/$workflow"
	mkdir -p "$dir"
	local tmp="$dir/.$kind.$$"
	printf '%s' "$after" >"$tmp" && mv "$tmp" "$dir/$kind"
}
