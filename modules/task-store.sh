# shellcheck shell=bash
## The store a factory's tasks live in (PRD-003 phase 2).
##
## A task is a directory and each of its fields is a file, for the same reason
## the factory declaration is a tree: a shell script reads a value by reading a
## file, which needs no parser, and a value that is its own file cannot be
## confused with its neighbour or truncated by one. Writes go through a
## temporary file and a rename, so a reader never sees half a value.
##
## Sourced by store path into cageworks-container alongside names.sh, whose
## cageworks_name_ok this file relies on.

## The states a task may hold. A task outlives its runs, so this says nothing
## about what a session is doing; that is the run's own machine.
CAGEWORKS_TASK_STATES="proposed ready running blocked awaiting-review done failed cancelled"

## The scalar fields that share one file and are therefore written together.
## Everything else is text written once, kept in a file of its own because a
## line-oriented file cannot hold a value with newlines (ADR-014).
CAGEWORKS_TASK_SCALARS="state attempts role workflow stage parent seq item gate"

cageworks_task_state_ok() {
	local candidate="$1" state
	for state in $CAGEWORKS_TASK_STATES; do
		[ "$state" = "$candidate" ] && return 0
	done
	return 1
}

cageworks_task_scalar() {
	local candidate="$1" field
	for field in $CAGEWORKS_TASK_SCALARS; do
		[ "$field" = "$candidate" ] && return 0
	done
	return 1
}

## Field names become file names, so they are held to the same alphabet as
## everything else that reaches a path.
cageworks_task_field_ok() {
	[[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]
}

cageworks_task_dir() {
	local root="$1" factory="$2" id="$3"
	cageworks_name_ok "$factory" || return 1
	[[ "$id" =~ ^task-[0-9]+$ ]] || return 1
	echo "$root/$factory/$id"
}

## Rewrite the scalar file whole, through a temporary and a rename, so a reader
## sees either every field from before the change or every field after it and
## never one from each.
cageworks_task_put_scalars() {
	local dir="$1"
	shift
	local tmp="$dir/.fields.$$"
	printf '%s\n' "$@" >"$tmp" && mv "$tmp" "$dir/fields"
}

cageworks_task_read_scalar() {
	local dir="$1" field="$2"
	[ -f "$dir/fields" ] || return 0
	local line
	while IFS= read -r line; do
		if [ "${line%%=*}" = "$field" ]; then
			echo "${line#*=}"
			return 0
		fi
	done <"$dir/fields"
}

## Ids are allocated by creating the directory: mkdir either succeeds or it
## does not, which is the atomic test-and-set a lock was previously wrapped
## around. A losing racer retries with the next number rather than waiting.
cageworks_task_new() {
	local root="$1" factory="$2" workflow="$3" stage="${4:-}"

	cageworks_name_ok "$factory" || return 1
	cageworks_name_ok "$workflow" || return 1

	local base="$root/$factory"
	mkdir -p "$base"

	local next id dir attempt=0
	while :; do
		next=1
		local path n
		for path in "$base"/task-*; do
			[ -d "$path" ] || continue
			n="$(basename "$path")"
			n="${n#task-}"
			n=$((10#$n + 1))
			[ "$n" -gt "$next" ] && next="$n"
		done
		id="$(printf 'task-%04d' "$next")"
		dir="$base/$id"
		if mkdir "$dir" 2>/dev/null; then
			break
		fi
		attempt=$((attempt + 1))
		if [ "$attempt" -gt 1000 ]; then
			echo "cageworks: could not allocate a task id under $base" >&2
			return 1
		fi
	done

	cageworks_task_put_scalars "$dir" \
		"state=proposed" \
		"attempts=0" \
		"role=" \
		"workflow=$workflow" \
		"stage=$stage" \
		"parent=" \
		"seq=$next" || return 1
	echo "$id"
}

cageworks_task_get() {
	local root="$1" factory="$2" id="$3" field="$4"
	cageworks_task_field_ok "$field" || return 1
	local dir
	dir="$(cageworks_task_dir "$root" "$factory" "$id")" || return 1
	[ -d "$dir" ] || return 1
	if cageworks_task_scalar "$field"; then
		cageworks_task_read_scalar "$dir" "$field"
		return 0
	fi
	[ -f "$dir/$field" ] || return 0
	cat "$dir/$field"
}

## Set one or more fields. Scalars are written together in one rename, which is
## what makes a change unable to half-happen; text is written to its own file.
cageworks_task_set() {
	local root="$1" factory="$2" id="$3"
	shift 3

	local dir
	dir="$(cageworks_task_dir "$root" "$factory" "$id")" || return 1
	[ -d "$dir" ] || return 1

	local -a pending=()
	local field value
	while [ $# -gt 0 ]; do
		field="$1"
		value="$2"
		shift 2
		cageworks_task_field_ok "$field" || return 1
		if [ "$field" = "state" ] && ! cageworks_task_state_ok "$value"; then
			echo "cageworks: not a task state: $value" >&2
			return 1
		fi
		if cageworks_task_scalar "$field"; then
			case "$value" in
			*$'\n'*)
				echo "cageworks: $field cannot contain a newline" >&2
				return 1
				;;
			esac
			pending+=("$field" "$value")
		else
			local tmp="$dir/.$field.$$"
			printf '%s' "$value" >"$tmp" && mv "$tmp" "$dir/$field" || return 1
		fi
	done

	[ "${#pending[@]}" -eq 0 ] && return 0

	## Read every scalar, replace the ones being set, write the file once.
	local -a out=()
	local current i replaced
	for field in $CAGEWORKS_TASK_SCALARS; do
		current="$(cageworks_task_read_scalar "$dir" "$field")"
		replaced=""
		for ((i = 0; i < ${#pending[@]}; i += 2)); do
			if [ "${pending[i]}" = "$field" ]; then
				current="${pending[i + 1]}"
				replaced=yes
			fi
		done
		: "$replaced"
		out+=("$field=$current")
	done
	cageworks_task_put_scalars "$dir" "${out[@]}"
}

## Oldest first, because ordering is FIFO and the way to change what runs next
## is to cancel what should not.
cageworks_task_list() {
	local root="$1" factory="$2" want="${3:-}"
	cageworks_name_ok "$factory" || return 1
	local base="$root/$factory"
	[ -d "$base" ] || return 0

	local dir id
	for dir in "$base"/task-*; do
		[ -d "$dir" ] || continue
		id="$(basename "$dir")"
		if [ -n "$want" ]; then
			[ "$(cageworks_task_read_scalar "$dir" state)" = "$want" ] || continue
		fi
		printf '%s %s\n' "$(cageworks_task_read_scalar "$dir" seq)" "$id"
	done | sort -n | cut -d' ' -f2
}

## A task becomes ready when it carries the fields its workflow declares
## required. The check is presence and nothing else: whether acceptance
## criteria are any good is a judgement, and judgement belongs in a cage.
## A task with no stated finish line would otherwise spend all its attempts
## discovering it cannot be done.
cageworks_task_ready() {
	local root="$1" factory="$2" id="$3"
	shift 3

	local state
	state="$(cageworks_task_get "$root" "$factory" "$id" state)" || return 1
	if [ "$state" != "proposed" ]; then
		echo "cageworks: $id is $state, not proposed" >&2
		return 1
	fi

	local field value
	for field in "$@"; do
		value="$(cageworks_task_get "$root" "$factory" "$id" "$field")" || return 1
		if [ -z "$value" ]; then
			echo "cageworks: $id is missing $field" >&2
			return 1
		fi
	done

	cageworks_task_set "$root" "$factory" "$id" state ready
}

## Take an attempt at a task. Every attempt is counted before the run starts,
## so a run that never reports back has still spent one: an attempt that only
## counted on success would let a task that always crashes run forever.
cageworks_task_attempt() {
	local root="$1" factory="$2" id="$3" max="$4"

	local state attempts
	state="$(cageworks_task_get "$root" "$factory" "$id" state)" || return 1
	if [ "$state" != "ready" ]; then
		echo "cageworks: $id is $state, not ready" >&2
		return 1
	fi

	attempts="$(cageworks_task_get "$root" "$factory" "$id" attempts)"
	if [ "$attempts" -ge "$max" ]; then
		echo "cageworks: $id has spent its $max attempts" >&2
		cageworks_task_set "$root" "$factory" "$id" state failed
		return 1
	fi

	## The count and the state move together. Two writes here is the defect
	## this store was reshaped to remove: a crash between them would leave an
	## attempt spent with the task still ready to take another (ADR-014).
	cageworks_task_set "$root" "$factory" "$id" \
		attempts "$((attempts + 1))" \
		state running
}

## A run settled: the session went idle and the role recorded what it did.
## An empty outcome is refused here rather than accepted as success, because a
## session that goes idle having recorded nothing is indistinguishable from one
## that crashed, and treating silence as completion would make a crash look
## like finished work.
cageworks_task_settle() {
	local root="$1" factory="$2" id="$3" outcome="$4"

	if [ -z "$outcome" ]; then
		echo "cageworks: $id settled without recording an outcome" >&2
		return 1
	fi
	cageworks_task_set "$root" "$factory" "$id" outcome "$outcome" || return 1
	cageworks_task_set "$root" "$factory" "$id" state awaiting-review
}

## A run failed: it crashed, outlived its limit, or went idle having recorded
## nothing. The task goes back to ready unless its attempts are gone, so work
## blocked on something external is not silently abandoned.
cageworks_task_failed() {
	local root="$1" factory="$2" id="$3" reason="$4" max="$5"

	cageworks_task_set "$root" "$factory" "$id" failure "$reason" || return 1

	local attempts
	attempts="$(cageworks_task_get "$root" "$factory" "$id" attempts)"
	if [ "$attempts" -ge "$max" ]; then
		cageworks_task_set "$root" "$factory" "$id" state failed
	else
		cageworks_task_set "$root" "$factory" "$id" state ready
	fi
}

## Cancelled by the operator or by a cap. Terminal, and it records why rather
## than leaving a task that simply stopped.
cageworks_task_cancel() {
	local root="$1" factory="$2" id="$3" reason="${4:-}"
	cageworks_task_set "$root" "$factory" "$id" failure "$reason" || return 1
	cageworks_task_set "$root" "$factory" "$id" state cancelled
}

## Move the work to the next stage. The finished task ends as done and the
## created one starts at the stage the pipeline puts it in, taken by nobody
## yet, carrying the workflow and the acceptance criteria it came with. Who
## works it is resolved from that stage's capability when it is taken, which is
## why no role is named here (ADR-015). A created task inherits its parent's
## workflow and cannot name another, so no cascade escapes the budget of the
## work that started it.
##
## The end of the pipeline is not a stage: reaching it finishes the work and
## creates nothing, which is why an empty next stage is a success.
cageworks_task_advance() {
	local root="$1" factory="$2" id="$3" next_stage="$4"

	local state
	state="$(cageworks_task_get "$root" "$factory" "$id" state)" || return 1
	if [ "$state" != "awaiting-review" ]; then
		echo "cageworks: $id is $state, not awaiting-review" >&2
		return 1
	fi

	local gate
	gate="$(cageworks_task_get "$root" "$factory" "$id" gate)"
	if [ -n "$gate" ]; then
		echo "cageworks: $id waits at the $gate gate" >&2
		return 1
	fi

	if [ -z "$next_stage" ]; then
		cageworks_task_set "$root" "$factory" "$id" state "done" || return 1
		return 0
	fi

	local workflow child
	workflow="$(cageworks_task_get "$root" "$factory" "$id" workflow)" || return 1
	child="$(cageworks_task_new "$root" "$factory" "$workflow" "$next_stage")" || return 1
	cageworks_task_set "$root" "$factory" "$child" parent "$id" || return 1
	cageworks_task_set "$root" "$factory" "$child" acceptance \
		"$(cageworks_task_get "$root" "$factory" "$id" acceptance)" || return 1
	cageworks_task_set "$root" "$factory" "$id" state "done" || return 1

	echo "$child"
}

## Hold settled work at a gate. The task stays awaiting-review and the gate
## names what it waits for, so a run that has finished its work is visibly
## waiting on a person rather than looking finished.
cageworks_task_gate() {
	local root="$1" factory="$2" id="$3" gate="$4"
	local state
	state="$(cageworks_task_get "$root" "$factory" "$id" state)" || return 1
	if [ "$state" != "awaiting-review" ]; then
		echo "cageworks: $id is $state, so there is nothing to hold" >&2
		return 1
	fi
	cageworks_task_set "$root" "$factory" "$id" gate "$gate"
}

## Answer a gate. Approval clears it and the work may move on; rejection sends
## the work back with the reason recorded rather than discarding it, and costs
## no attempt, because a rejection is a decision rather than a failure.
cageworks_task_answer() {
	local root="$1" factory="$2" id="$3" answer="$4" reason="${5:-}"

	local gate
	gate="$(cageworks_task_get "$root" "$factory" "$id" gate)" || return 1
	if [ -z "$gate" ]; then
		echo "cageworks: $id is not waiting at a gate" >&2
		return 1
	fi

	[ -n "$reason" ] && cageworks_task_set "$root" "$factory" "$id" answer "$reason"

	case "$answer" in
	approve)
		cageworks_task_set "$root" "$factory" "$id" gate ""
		;;
	reject)
		cageworks_task_set "$root" "$factory" "$id" gate "" state ready
		;;
	*)
		echo "cageworks: an answer is approve or reject, not $answer" >&2
		return 1
		;;
	esac
}

## Record which role took a task. Taking happens once: every later attempt goes
## to the role that holds the branch, so a retry continues the first attempt's
## commits instead of starting again in a namespace it cannot write (ADR-015).
##
## Taking again with the same role is how a retry passes through here; taking
## with another is refused rather than silently reassigned.
cageworks_task_take() {
	local root="$1" factory="$2" id="$3" role="$4"
	cageworks_name_ok "$role" || return 1

	local taken
	taken="$(cageworks_task_get "$root" "$factory" "$id" role)" || return 1
	if [ -n "$taken" ]; then
		if [ "$taken" != "$role" ]; then
			echo "cageworks: $id was taken by $taken, not $role" >&2
			return 1
		fi
		return 0
	fi

	cageworks_task_set "$root" "$factory" "$id" role "$role"
}
