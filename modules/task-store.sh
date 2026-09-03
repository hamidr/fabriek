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
	local root="$1" factory="$2" workflow="$3" role="$4" stage="${5:-}"

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
	[ -n "$stage" ] && printf '%s' "$stage" >"$dir/stage"
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

## Take an attempt at a task. Every attempt is counted before the run starts,
## so a run that never reports back has still spent one: an attempt that only
## counted on success would let a task that always crashes run forever.
nixcage_task_attempt() {
	local root="$1" factory="$2" id="$3" max="$4"

	local state attempts
	state="$(nixcage_task_get "$root" "$factory" "$id" state)" || return 1
	if [ "$state" != "ready" ]; then
		echo "nixcage: $id is $state, not ready" >&2
		return 1
	fi

	attempts="$(nixcage_task_get "$root" "$factory" "$id" attempts)"
	if [ "$attempts" -ge "$max" ]; then
		echo "nixcage: $id has spent its $max attempts" >&2
		nixcage_task_set "$root" "$factory" "$id" state failed
		return 1
	fi

	nixcage_task_set "$root" "$factory" "$id" attempts "$((attempts + 1))" || return 1
	nixcage_task_set "$root" "$factory" "$id" state running
}

## A run settled: the session went idle and the role recorded what it did.
## An empty outcome is refused here rather than accepted as success, because a
## session that goes idle having recorded nothing is indistinguishable from one
## that crashed, and treating silence as completion would make a crash look
## like finished work.
nixcage_task_settle() {
	local root="$1" factory="$2" id="$3" outcome="$4"

	if [ -z "$outcome" ]; then
		echo "nixcage: $id settled without recording an outcome" >&2
		return 1
	fi
	nixcage_task_set "$root" "$factory" "$id" outcome "$outcome" || return 1
	nixcage_task_set "$root" "$factory" "$id" state awaiting-review
}

## A run failed: it crashed, outlived its limit, or went idle having recorded
## nothing. The task goes back to ready unless its attempts are gone, so work
## blocked on something external is not silently abandoned.
nixcage_task_failed() {
	local root="$1" factory="$2" id="$3" reason="$4" max="$5"

	nixcage_task_set "$root" "$factory" "$id" failure "$reason" || return 1

	local attempts
	attempts="$(nixcage_task_get "$root" "$factory" "$id" attempts)"
	if [ "$attempts" -ge "$max" ]; then
		nixcage_task_set "$root" "$factory" "$id" state failed
	else
		nixcage_task_set "$root" "$factory" "$id" state ready
	fi
}

## Cancelled by the operator or by a cap. Terminal, and it records why rather
## than leaving a task that simply stopped.
nixcage_task_cancel() {
	local root="$1" factory="$2" id="$3" reason="${4:-}"
	nixcage_task_set "$root" "$factory" "$id" failure "$reason" || return 1
	nixcage_task_set "$root" "$factory" "$id" state cancelled
}

## Move the work to the next stage. The finished task ends as done and the
## created one starts at the stage the pipeline puts it in, owned by that
## stage's role, carrying the workflow and the acceptance criteria it came
## with. A created task inherits its parent's workflow and cannot name
## another, so no cascade escapes the budget of the work that started it.
##
## The end of the pipeline is not a stage: reaching it finishes the work and
## creates nothing, which is why an empty next stage is a success.
nixcage_task_advance() {
	local root="$1" factory="$2" id="$3" next_stage="$4" next_role="$5"

	local state
	state="$(nixcage_task_get "$root" "$factory" "$id" state)" || return 1
	if [ "$state" != "awaiting-review" ]; then
		echo "nixcage: $id is $state, not awaiting-review" >&2
		return 1
	fi

	if [ -z "$next_stage" ]; then
		nixcage_task_set "$root" "$factory" "$id" state "done" || return 1
		return 0
	fi

	local workflow child
	workflow="$(nixcage_task_get "$root" "$factory" "$id" workflow)" || return 1
	child="$(nixcage_task_new "$root" "$factory" "$workflow" "$next_role" "$next_stage")" || return 1
	nixcage_task_set "$root" "$factory" "$child" parent "$id" || return 1
	nixcage_task_set "$root" "$factory" "$child" acceptance \
		"$(nixcage_task_get "$root" "$factory" "$id" acceptance)" || return 1
	nixcage_task_set "$root" "$factory" "$id" state "done" || return 1
	echo "$child"
}
