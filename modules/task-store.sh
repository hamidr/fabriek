# shellcheck shell=bash
## The store a factory's tasks live in (PRD-003 phase 2).
##
## A task is a directory and each of its fields is a file, for the same reason
## the factory declaration is a tree: a shell script reads a value by reading a
## file, which needs no parser, and a value that is its own file cannot be
## confused with its neighbour or truncated by one. Writes go through a
## temporary file and a rename, so a reader never sees half a value.
##
## Sourced by store path into nixcage-container alongside role-uid.sh, whose
## nixcage_role_name_ok this file relies on.

## The states a task may hold. A task outlives its runs, so this says nothing
## about what a session is doing; that is the run's own machine.
NIXCAGE_TASK_STATES="proposed ready running blocked awaiting-review done failed cancelled"

nixcage_task_state_ok() {
	local candidate="$1" state
	for state in $NIXCAGE_TASK_STATES; do
		[ "$state" = "$candidate" ] && return 0
	done
	return 1
}

## Field names become file names, so they are held to the same alphabet as
## everything else that reaches a path.
nixcage_task_field_ok() {
	[[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]
}

nixcage_task_dir() {
	local root="$1" factory="$2" id="$3"
	nixcage_role_name_ok "$factory" || return 1
	[[ "$id" =~ ^task-[0-9]+$ ]] || return 1
	echo "$root/$factory/$id"
}

## Ids are allocated strictly increasing and never reissued: a reused id would
## attach a new task to whatever the old one left behind, in a record whose
## whole purpose is saying what happened.
nixcage_task_new() {
	local root="$1" factory="$2" workflow="$3" role="$4"

	nixcage_role_name_ok "$factory" || return 1
	nixcage_role_name_ok "$workflow" || return 1
	nixcage_role_name_ok "$role" || return 1

	local base="$root/$factory"
	mkdir -p "$base"

	nixcage_role_lock "$base/.seq" || return 1
	trap 'nixcage_role_unlock "$base/.seq"' RETURN

	local next=1
	[ -f "$base/.seq" ] && next="$(cat "$base/.seq")"
	printf '%s' "$((next + 1))" >"$base/.seq"

	local id
	id="$(printf 'task-%04d' "$next")"
	local dir="$base/$id"
	mkdir -p "$dir"
	printf '%s' "proposed" >"$dir/state"
	printf '%s' "$role" >"$dir/role"
	printf '%s' "$workflow" >"$dir/workflow"
	printf '%s' "0" >"$dir/attempts"
	printf '%s' "$next" >"$dir/seq"
	echo "$id"
}

nixcage_task_get() {
	local root="$1" factory="$2" id="$3" field="$4"
	nixcage_task_field_ok "$field" || return 1
	local dir
	dir="$(nixcage_task_dir "$root" "$factory" "$id")" || return 1
	[ -d "$dir" ] || return 1
	[ -f "$dir/$field" ] || return 0
	cat "$dir/$field"
}

nixcage_task_set() {
	local root="$1" factory="$2" id="$3" field="$4" value="$5"
	nixcage_task_field_ok "$field" || return 1
	if [ "$field" = "state" ] && ! nixcage_task_state_ok "$value"; then
		echo "nixcage: not a task state: $value" >&2
		return 1
	fi
	local dir
	dir="$(nixcage_task_dir "$root" "$factory" "$id")" || return 1
	[ -d "$dir" ] || return 1
	local tmp="$dir/.$field.$$"
	printf '%s' "$value" >"$tmp" && mv "$tmp" "$dir/$field"
}

## Oldest first, because ordering is FIFO and the way to change what runs next
## is to cancel what should not.
nixcage_task_list() {
	local root="$1" factory="$2" want="${3:-}"
	nixcage_role_name_ok "$factory" || return 1
	local base="$root/$factory"
	[ -d "$base" ] || return 0

	local dir id
	for dir in "$base"/task-*; do
		[ -d "$dir" ] || continue
		id="$(basename "$dir")"
		if [ -n "$want" ]; then
			[ "$(cat "$dir/state" 2>/dev/null)" = "$want" ] || continue
		fi
		printf '%s %s\n' "$(cat "$dir/seq" 2>/dev/null || echo 0)" "$id"
	done | sort -n | cut -d' ' -f2
}

## A task becomes ready when it carries the fields its workflow declares
## required. The check is presence and nothing else: whether acceptance
## criteria are any good is a judgement, and judgement belongs in a cage.
## A task with no stated finish line would otherwise spend all its attempts
## discovering it cannot be done.
nixcage_task_ready() {
	local root="$1" factory="$2" id="$3"
	shift 3

	local state
	state="$(nixcage_task_get "$root" "$factory" "$id" state)" || return 1
	if [ "$state" != "proposed" ]; then
		echo "nixcage: $id is $state, not proposed" >&2
		return 1
	fi

	local field value
	for field in "$@"; do
		value="$(nixcage_task_get "$root" "$factory" "$id" "$field")" || return 1
		if [ -z "$value" ]; then
			echo "nixcage: $id is missing $field" >&2
			return 1
		fi
	done

	nixcage_task_set "$root" "$factory" "$id" state ready
}
