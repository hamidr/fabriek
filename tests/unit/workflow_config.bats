#!/usr/bin/env bats
# Reading a declared pipeline: the capability each stage needs, its own entry
# and exit policy, and who may ask whom (ADR-015).
#
# A stage's index is its position in the declared list (ADR-020), which is what
# makes "the stage after this one" a question with an answer.

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/names.sh
	source "$CAGEWORKS_ROOT/modules/names.sh"
	# shellcheck source=../../modules/workflow-config.sh
	source "$CAGEWORKS_ROOT/modules/workflow-config.sh"
	DECL="$TEST_TEMP_DIR/declaration.json"
	cat >"$DECL" <<'JSON'
{
  "name": "acme",
  "roles": {
    "architect": { "provides": ["design"] },
    "builder": { "provides": ["build"] },
    "reviewer": { "provides": ["review"] }
  },
  "workflows": {
    "ship": {
      "stages": [
        { "needs": "design" },
        {
          "needs": "build",
          "fanout": true,
          "ready": ["acceptance", "body"],
          "done": "tests pass and the diff is small"
        },
        { "needs": "review", "gate": "before-integration" }
      ],
      "consults": { "builder": ["architect"] }
    }
  }
}
JSON
}

teardown() {
	teardown_temp_dir
}

## Replace the declaration with one jq edit applied to it.
declare_with() {
	local edited
	edited="$(jq "$1" "$DECL")"
	printf '%s\n' "$edited" >"$DECL"
}

@test "a workflow's stages come back in the order they were declared" {
	run cageworks_workflow_stages "$DECL" ship
	assert_success
	assert_line --index 0 "0 design"
	assert_line --index 1 "1 build"
	assert_line --index 2 "2 review"
}

@test "a goal enters at the first stage" {
	run cageworks_workflow_entry "$DECL" ship
	assert_success
	assert_output "0 design"
}

@test "each stage knows which one follows it" {
	run cageworks_workflow_next "$DECL" ship 0
	assert_success
	assert_output "1 build"
}

@test "the last stage has nothing after it, and that is not an error" {
	run cageworks_workflow_next "$DECL" ship 2
	assert_success
	assert_output ""
}

@test "a stage that fans out says so" {
	run cageworks_workflow_stage_fans_out "$DECL" ship 1
	assert_success
	run cageworks_workflow_stage_fans_out "$DECL" ship 0
	assert_failure
}

@test "a stage that carries a gate names it" {
	run cageworks_workflow_stage_gate "$DECL" ship 2
	assert_success
	assert_output "before-integration"
	run cageworks_workflow_stage_gate "$DECL" ship 0
	assert_output ""
}

@test "a role may ask only who the declaration connects it to" {
	run cageworks_workflow_may_consult "$DECL" ship builder architect
	assert_success
	run cageworks_workflow_may_consult "$DECL" ship builder reviewer
	assert_failure
	run cageworks_workflow_may_consult "$DECL" ship reviewer architect
	assert_failure
}

@test "the consult graph may point backwards, which the pipeline may not" {
	# builder is stage 1 and architect is stage 0: asking backwards is the point.
	run cageworks_workflow_may_consult "$DECL" ship builder architect
	assert_success
}

@test "an undeclared workflow is refused by name" {
	run cageworks_workflow_stages "$DECL" ghost
	assert_failure
	assert_output --partial "ghost"
}

@test "a workflow name that could reach a path or a ref is refused" {
	run cageworks_workflow_stages "$DECL" "../../etc"
	assert_failure
}

@test "a workflow with no stages is refused rather than silently empty" {
	declare_with '.workflows.bare = { "stages": [] }'
	run cageworks_workflow_stages "$DECL" bare
	assert_failure
	assert_output --partial "no stages"
}

@test "a workflow declares what it may spend" {
	declare_with '.workflows.ship.budget = { "runs": 40, "tokens": 2000000 }'
	[ "$(cageworks_workflow_budget "$DECL" ship runs)" = "40" ]
	[ "$(cageworks_workflow_budget "$DECL" ship tokens)" = "2000000" ]
}

@test "a workflow that declares no budget is unbounded rather than forbidden" {
	run cageworks_workflow_budget "$DECL" ship runs
	assert_success
	assert_output "0"
}

@test "a stage names the capability it needs, not a role" {
	run cageworks_workflow_stage_needs "$DECL" ship 1
	assert_success
	assert_output "build"
}

@test "a stage states which fields a task must carry before it may be taken" {
	run cageworks_workflow_stage_ready "$DECL" ship 1
	assert_success
	assert_line --index 0 "acceptance"
	assert_line --index 1 "body"
}

@test "a stage that requires nothing requires nothing, and that is not an error" {
	run cageworks_workflow_stage_ready "$DECL" ship 0
	assert_success
	assert_output ""
}

@test "a stage's finish line is prose, handed over as written" {
	run cageworks_workflow_stage_done "$DECL" ship 1
	assert_success
	assert_output "tests pass and the diff is small"
}

@test "a stage that states no finish line states none" {
	run cageworks_workflow_stage_done "$DECL" ship 2
	assert_success
	assert_output ""
}
