# shellcheck shell=bash
## Reading a declared pipeline out of the declaration its repository carries
## (PRD-003 phase 3, moved by ADR-020).
##
## A workflow is stages in order plus a separate graph saying who may ask whom.
## The pipeline moves work forward and is a list, so it cannot contain a cycle
## and every stage is reachable by construction. The consult graph may point
## backwards, because the role that can answer a question is usually the one
## that came before, and it is kept safe by consults being leaves rather than
## by its shape.
##
## A stage's index is its position in that list, which is what makes "the stage
## after this one" a question with an answer. Sourced by store path into
## cageworks-container alongside names.sh.

## Whether a workflow is one this declaration declares.
cageworks_workflow_declared() {
	local declaration="$1" workflow="$2"
	cageworks_name_ok "$workflow" || return 1
	if [ "$(jq -r --arg w "$workflow" '(.workflows // {}) | has($w)' "$declaration")" = "true" ]; then
		return 0
	fi
	echo "cageworks: no workflow declared as $workflow" >&2
	return 1
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
	local declaration="$1" workflow="$2" stages
	cageworks_workflow_declared "$declaration" "$workflow" || return 1
	stages="$(jq -r --arg w "$workflow" '
    (.workflows[$w].stages // []) | to_entries | .[] | "\(.key) \(.value.needs // "")"' \
		"$declaration")" || return 1
	if [ -z "$stages" ]; then
		echo "cageworks: workflow $workflow declares no stages" >&2
		return 1
	fi
	printf '%s\n' "$stages"
}

## Where a filed goal enters.
cageworks_workflow_entry() {
	cageworks_workflow_stages "$1" "$2" | head -1
}

## The stage after this one, or nothing at the end of the pipeline. Reaching
## the end is how work finishes, not an error.
cageworks_workflow_next() {
	local declaration="$1" workflow="$2" index="$3"
	local seen="" line
	while IFS= read -r line; do
		if [ -n "$seen" ]; then
			echo "$line"
			return 0
		fi
		[ "${line%% *}" = "$index" ] && seen=yes
	done < <(cageworks_workflow_stages "$declaration" "$workflow") || return 1
	echo ""
}

## One field of one stage, or nothing when it declares none. Every reader below
## is this with a field name, so a stage gains a field by gaining a reader
## rather than by gaining a way of being read.
cageworks_workflow_stage_field() {
	local declaration="$1" workflow="$2" index="$3" field="$4"
	cageworks_workflow_declared "$declaration" "$workflow" || return 1
	jq -r --arg w "$workflow" --argjson i "$index" --arg f "$field" '
    (.workflows[$w].stages[$i][$f] // empty)
    | if type == "array" then .[] else . end' "$declaration"
}

## The capability a stage needs. Unlike the rest, a stage without one is a
## stage nothing can take, so it is an error rather than an absence.
cageworks_workflow_stage_needs() {
	local needs
	needs="$(cageworks_workflow_stage_field "$1" "$2" "$3" needs)" || return 1
	[ -n "$needs" ] || return 1
	printf '%s\n' "$needs"
}

## The fields a task must carry before this stage may take it, one per line.
## Checked for presence and nothing else: it is a metadata check, and reads
## nothing anyone wrote (ADR-015).
cageworks_workflow_stage_ready() {
	cageworks_workflow_stage_field "$1" "$2" "$3" ready
}

## What finishing means at this stage, as prose. Never enforced: judging
## whether work meets a bar is reading content, which belongs in a cage, so
## this is handed to the role that will judge it (ADR-015).
cageworks_workflow_stage_done() {
	cageworks_workflow_stage_field "$1" "$2" "$3" "done"
}

cageworks_workflow_stage_gate() {
	cageworks_workflow_stage_field "$1" "$2" "$3" gate
}

cageworks_workflow_stage_fans_out() {
	local fanout
	fanout="$(cageworks_workflow_stage_field "$1" "$2" "$3" fanout)" || return 1
	[ "$fanout" = "true" ]
}

## Whether one role may ask another. Declared per asking role, and deliberately
## allowed to point backwards: a consult creates a leaf task, so no chain of
## roles waiting on each other can close into a loop whatever this graph says.
cageworks_workflow_may_consult() {
	local declaration="$1" workflow="$2" asker="$3" target="$4"
	cageworks_name_ok "$asker" || return 1
	cageworks_name_ok "$target" || return 1
	cageworks_workflow_declared "$declaration" "$workflow" || return 1
	[ "$(jq -r --arg w "$workflow" --arg a "$asker" --arg t "$target" '
    ((.workflows[$w].consults // {})[$a] // []) | index($t) != null' "$declaration")" = "true" ]
}

## What a workflow may spend, by kind. Absent means unbounded: a workflow
## nobody has bounded yet is not a workflow that may not run.
cageworks_workflow_budget() {
	local declaration="$1" workflow="$2" kind="$3"
	cageworks_workflow_declared "$declaration" "$workflow" || return 1
	jq -r --arg w "$workflow" --arg k "$kind" '(.workflows[$w].budget[$k] // 0)' "$declaration"
}
