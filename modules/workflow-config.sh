# shellcheck shell=bash
## Reading a declared pipeline (PRD-003 phase 3).
##
## A workflow is stages in order plus a separate graph saying who may ask whom.
## The pipeline moves work forward and is a list, so it cannot contain a cycle
## and every stage is reachable by construction. The consult graph may point
## backwards, because the role that can answer a question is usually the one
## that came before, and it is kept safe by consults being leaves rather than
## by its shape.
##
## Rendered as a directory tree for the reason the rest of the declaration is:
## a shell script reads a value by reading a file. Sourced by store path into
## cageworks-container alongside names.sh.

cageworks_workflow_dir() {
	local root="$1" factory="$2" workflow="$3"
	cageworks_name_ok "$factory" || return 1
	cageworks_name_ok "$workflow" || return 1
	echo "$root/$factory/workflows/$workflow"
}

## Every stage as "<index> <capability>", in declaration order. A stage names
## what it needs done rather than who does it (ADR-015), so several roles can
## work one stage at once and capacity is added by declaring a role instead of
## by editing the pipeline.
##
## A workflow with no stages is a declaration mistake rather than an empty
## pipeline, so it is refused here instead of producing a workflow nothing can
## run.
cageworks_workflow_stages() {
	local root="$1" factory="$2" workflow="$3"
	local dir
	dir="$(cageworks_workflow_dir "$root" "$factory" "$workflow")" || return 1
	if [ ! -d "$dir" ]; then
		echo "cageworks: no workflow declared as $workflow" >&2
		return 1
	fi

	local -a stages=()
	local path index
	for path in "$dir"/stages/*; do
		[ -d "$path" ] || continue
		index="$(basename "$path")"
		stages+=("$index $(cat "$path/needs" 2>/dev/null)")
	done
	if [ "${#stages[@]}" -eq 0 ]; then
		echo "cageworks: workflow $workflow declares no stages" >&2
		return 1
	fi
	printf '%s\n' "${stages[@]}" | sort
}

## Where a filed goal enters.
cageworks_workflow_entry() {
	cageworks_workflow_stages "$1" "$2" "$3" | head -1
}

## The stage after this one, or nothing at the end of the pipeline. Reaching
## the end is how work finishes, not an error.
cageworks_workflow_next() {
	local root="$1" factory="$2" workflow="$3" index="$4"
	local seen="" line
	while IFS= read -r line; do
		if [ -n "$seen" ]; then
			echo "$line"
			return 0
		fi
		[ "${line%% *}" = "$index" ] && seen=yes
	done < <(cageworks_workflow_stages "$root" "$factory" "$workflow") || return 1
	echo ""
}

## The capability a stage needs.
cageworks_workflow_stage_needs() {
	local root="$1" factory="$2" workflow="$3" index="$4"
	local dir
	dir="$(cageworks_workflow_dir "$root" "$factory" "$workflow")" || return 1
	[ -f "$dir/stages/$index/needs" ] || return 1
	cat "$dir/stages/$index/needs"
}

## The fields a task must carry before this stage may take it, one per line.
## Checked for presence and nothing else: it is a metadata check, and reads
## nothing anyone wrote (ADR-015).
cageworks_workflow_stage_ready() {
	local root="$1" factory="$2" workflow="$3" index="$4"
	local dir
	dir="$(cageworks_workflow_dir "$root" "$factory" "$workflow")" || return 1
	[ -f "$dir/stages/$index/ready" ] || return 0
	cat "$dir/stages/$index/ready"
}

## What finishing means at this stage, as prose. Never enforced: judging
## whether work meets a bar is reading content, which belongs in a cage, so
## this is handed to the role that will judge it (ADR-015).
cageworks_workflow_stage_done() {
	local root="$1" factory="$2" workflow="$3" index="$4"
	local dir
	dir="$(cageworks_workflow_dir "$root" "$factory" "$workflow")" || return 1
	[ -f "$dir/stages/$index/done" ] || return 0
	cat "$dir/stages/$index/done"
}

cageworks_workflow_stage_fans_out() {
	local root="$1" factory="$2" workflow="$3" index="$4"
	local dir
	dir="$(cageworks_workflow_dir "$root" "$factory" "$workflow")" || return 1
	[ -f "$dir/stages/$index/fanout" ]
}

cageworks_workflow_stage_gate() {
	local root="$1" factory="$2" workflow="$3" index="$4"
	local dir
	dir="$(cageworks_workflow_dir "$root" "$factory" "$workflow")" || return 1
	[ -f "$dir/stages/$index/gate" ] || return 0
	cat "$dir/stages/$index/gate"
}

## Whether one role may ask another. Declared per asking role, and deliberately
## allowed to point backwards: a consult creates a leaf task, so no chain of
## roles waiting on each other can close into a loop whatever this graph says.
cageworks_workflow_may_consult() {
	local root="$1" factory="$2" workflow="$3" asker="$4" target="$5"
	cageworks_name_ok "$asker" || return 1
	cageworks_name_ok "$target" || return 1
	local dir
	dir="$(cageworks_workflow_dir "$root" "$factory" "$workflow")" || return 1
	[ -e "$dir/consults/$asker/$target" ]
}

## What a workflow may spend, by kind. Absent means unbounded: a workflow
## nobody has bounded yet is not a workflow that may not run.
cageworks_workflow_budget() {
	local root="$1" factory="$2" workflow="$3" kind="$4"
	local dir
	dir="$(cageworks_workflow_dir "$root" "$factory" "$workflow")" || return 1
	if [ -f "$dir/budget-$kind" ]; then
		cat "$dir/budget-$kind"
	else
		echo 0
	fi
}
