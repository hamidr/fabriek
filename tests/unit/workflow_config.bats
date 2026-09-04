#!/usr/bin/env bats
# Reading a declared pipeline: the capability each stage needs, its own entry
# and exit policy, and who may ask whom (ADR-015).

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/role-uid.sh
	source "$NIXCAGE_ROOT/modules/role-uid.sh"
	# shellcheck source=../../modules/workflow-config.sh
	source "$NIXCAGE_ROOT/modules/workflow-config.sh"
	ROOT="$TEST_TEMP_DIR/factories"
	W="$ROOT/acme/workflows/ship"
	mkdir -p "$W/stages/00" "$W/stages/01" "$W/stages/02" "$W/consults/builder"
	echo design >"$W/stages/00/needs"
	echo build >"$W/stages/01/needs"
	: >"$W/stages/01/fanout"
	printf 'acceptance\nbody\n' >"$W/stages/01/ready"
	printf 'tests pass and the diff is small\n' >"$W/stages/01/done"
	echo review >"$W/stages/02/needs"
	echo before-integration >"$W/stages/02/gate"
	: >"$W/consults/builder/architect"
}

teardown() {
	teardown_temp_dir
}

@test "a workflow's stages come back in the order they were declared" {
	run nixcage_workflow_stages "$ROOT" acme ship
	assert_success
	assert_line --index 0 "00 design"
	assert_line --index 1 "01 build"
	assert_line --index 2 "02 review"
}

@test "a goal enters at the first stage" {
	run nixcage_workflow_entry "$ROOT" acme ship
	assert_success
	assert_output "00 design"
}

@test "each stage knows which one follows it" {
	run nixcage_workflow_next "$ROOT" acme ship 00
	assert_success
	assert_output "01 build"
}

@test "the last stage has nothing after it, and that is not an error" {
	run nixcage_workflow_next "$ROOT" acme ship 02
	assert_success
	assert_output ""
}

@test "a stage that fans out says so" {
	run nixcage_workflow_stage_fans_out "$ROOT" acme ship 01
	assert_success
	run nixcage_workflow_stage_fans_out "$ROOT" acme ship 00
	assert_failure
}

@test "a stage that carries a gate names it" {
	run nixcage_workflow_stage_gate "$ROOT" acme ship 02
	assert_success
	assert_output "before-integration"
	run nixcage_workflow_stage_gate "$ROOT" acme ship 00
	assert_output ""
}

@test "a role may ask only who the declaration connects it to" {
	run nixcage_workflow_may_consult "$ROOT" acme ship builder architect
	assert_success
	run nixcage_workflow_may_consult "$ROOT" acme ship builder reviewer
	assert_failure
	run nixcage_workflow_may_consult "$ROOT" acme ship reviewer architect
	assert_failure
}

@test "the consult graph may point backwards, which the pipeline may not" {
	# builder is stage 01 and architect is stage 00: asking backwards is the point.
	run nixcage_workflow_may_consult "$ROOT" acme ship builder architect
	assert_success
}

@test "an undeclared workflow is refused by name" {
	run nixcage_workflow_stages "$ROOT" acme ghost
	assert_failure
	assert_output --partial "ghost"
}

@test "a workflow name that could escape the declaration tree is refused" {
	run nixcage_workflow_stages "$ROOT" acme "../../etc"
	assert_failure
}

@test "a workflow with no stages is refused rather than silently empty" {
	mkdir -p "$ROOT/acme/workflows/bare/stages"
	run nixcage_workflow_stages "$ROOT" acme bare
	assert_failure
	assert_output --partial "no stages"
}

@test "a workflow declares what it may spend" {
	printf '40\n' >"$W/budget-runs"
	printf '2000000\n' >"$W/budget-tokens"
	[ "$(nixcage_workflow_budget "$ROOT" acme ship runs)" = "40" ]
	[ "$(nixcage_workflow_budget "$ROOT" acme ship tokens)" = "2000000" ]
}

@test "a workflow that declares no budget is unbounded rather than forbidden" {
	run nixcage_workflow_budget "$ROOT" acme ship runs
	assert_success
	assert_output "0"
}

@test "a stage names the capability it needs, not a role" {
	run nixcage_workflow_stage_needs "$ROOT" acme ship 01
	assert_success
	assert_output "build"
}

@test "a stage states which fields a task must carry before it may be taken" {
	run nixcage_workflow_stage_ready "$ROOT" acme ship 01
	assert_success
	assert_line --index 0 "acceptance"
	assert_line --index 1 "body"
}

@test "a stage that requires nothing requires nothing, and that is not an error" {
	run nixcage_workflow_stage_ready "$ROOT" acme ship 00
	assert_success
	assert_output ""
}

@test "a stage's finish line is prose, handed over as written" {
	run nixcage_workflow_stage_done "$ROOT" acme ship 01
	assert_success
	assert_output "tests pass and the diff is small"
}

@test "a stage that states no finish line states none" {
	run nixcage_workflow_stage_done "$ROOT" acme ship 02
	assert_success
	assert_output ""
}
