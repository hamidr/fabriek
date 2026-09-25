#!/usr/bin/env bats
# What a factory asks of the machine, met by what the operator allows
# (ADR-020 point 5).

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/sizes.sh
	source "$FABRIEK_ROOT/modules/sizes.sh"
	# shellcheck source=../../modules/resources.sh
	source "$FABRIEK_ROOT/modules/resources.sh"
	CAPS="$TEST_TEMP_DIR/caps.json"
	cat >"$CAPS" <<'JSON'
{ "memory": "16G", "cores": 8, "concurrency": 4 }
JSON
}

teardown() {
	teardown_temp_dir
}

## A declaration asking for the given resources and nothing else that matters
## to clamping.
asking_for() {
	printf '{ "name": "acme", "resources": %s }\n' "$1"
}

## What the factory ends up allowed, ignoring what was said while deciding it.
clamped() {
	asking_for "$1" | fabriek_resources_clamp "$CAPS" 2>/dev/null | jq -c .resources
}

## What was said about the clamping, ignoring the result.
clamp_said() {
	asking_for "$1" | fabriek_resources_clamp "$CAPS" 2>&1 >/dev/null
}

## The clamp's own verdict on what a factory asked for. run() cannot drive a
## pipeline through a sourced function, so the pipeline is here.
clamp_verdict() {
	asking_for "$1" | fabriek_resources_clamp "$CAPS" >/dev/null
}

## A whole declaration through the clamp, to see what else it touched. The
## result is captured rather than piped so that the clamp's own verdict is what
## the test sees, and not jq's.
clamp_whole() {
	local out
	out="$(printf '%s\n' "$1" | fabriek_resources_clamp "$CAPS" 2>/dev/null)" || return 1
	printf '%s\n' "$out" | jq -c .
}

## A declaration the clamp should refuse, and what it said about it.
clamp_refusal() {
	local said status
	said="$(printf '%s\n' "$1" | fabriek_resources_clamp "$CAPS" 2>&1 >/dev/null)"
	status=$?
	printf '%s\n' "$said"
	return "$status"
}

@test "a factory asking for less than it may have is left alone" {
	run clamped '{ "memory": "8G", "cores": 4 }'
	assert_success
	assert_output '{"memory":"8G","cores":4}'
}

@test "a factory asking for more than it may have gets the ceiling" {
	run clamped '{ "memory": "32G", "cores": 16 }'
	assert_success
	assert_output '{"memory":"16G","cores":8}'
}

# Clamping the strings instead of the sizes would read 8G as larger than 16G
# and hand this factory twice what the operator allowed.
@test "a size below its ceiling is kept even when its string sorts above it" {
	run clamped '{ "memory": "8G" }'
	assert_success
	assert_output '{"memory":"8G"}'
}

@test "asking for exactly the ceiling is not clamping, and is not reported" {
	run clamp_said '{ "cores": 8 }'
	assert_success
	assert_output ""
}

@test "clamping says which field it clamped, from what, and to what" {
	run clamp_said '{ "memory": "32G" }'
	assert_success
	assert_output --partial "memory"
	assert_output --partial "32G"
	assert_output --partial "16G"
}

@test "a field the factory does not ask for does not become the ceiling" {
	run clamped '{ "cores": 2 }'
	assert_success
	assert_output '{"cores":2}'
}

@test "a factory asking for nothing comes back asking for nothing" {
	run clamp_whole '{"name":"acme"}'
	assert_success
	assert_output '{"name":"acme"}'
}

# The operator's file is theirs, and a ceiling they did not set is not one.
@test "a field with no ceiling is left as the factory asked for it" {
	echo '{ "memory": "16G" }' >"$CAPS"
	run clamped '{ "cores": 64 }'
	assert_success
	assert_output '{"cores":64}'
}

@test "a size that is not one is refused rather than clamped to something" {
	run clamp_refusal '{"resources":{"memory":"plenty"}}'
	assert_failure
	assert_output --partial "plenty"
}

@test "a ceiling that is not a size is the operator's mistake, and is refused" {
	echo '{ "memory": "loads" }' >"$CAPS"
	run clamp_refusal '{"resources":{"memory":"8G"}}'
	assert_failure
	assert_output --partial "loads"
}

@test "everything else in the declaration survives being clamped" {
	run clamp_whole '{"name":"acme","roles":{"b":{}},"resources":{"cores":16}}'
	assert_success
	assert_output '{"name":"acme","roles":{"b":{}},"resources":{"cores":8}}'
}

# The declaration's schema and the operator's caps both read this, so a field
# added in one place is a field both of them know about.
@test "the fields a factory may ask for are one table, so both readers agree" {
	run fabriek_resource_field_names_json
	assert_success
	assert_output '["memory","cores","tokens","concurrency","taskAttempts","runTimeoutSeconds","egress"]'
}

# Egress is a permission rather than a size, and it is in the same table so
# that a field cannot exist for the declaration and not for the operator. What
# differs is how it meets its ceiling: by intersection, and refusing by default
# rather than allowing (ADR-025).

@test "a factory reaches only the endpoints the operator also allows" {
	cat >"$CAPS" <<'JSON'
{ "egress": ["api.anthropic.com", "api.openai.com"] }
JSON
	run clamped '{ "egress": ["api.anthropic.com", "evil.example"] }'
	[ "$output" = '{"egress":["api.anthropic.com"]}' ]
}

@test "a factory cannot widen its own reach by declaring more" {
	cat >"$CAPS" <<'JSON'
{ "egress": ["api.anthropic.com"] }
JSON
	run clamped '{ "egress": ["api.anthropic.com", "api.openai.com", "evil.example"] }'
	[ "$output" = '{"egress":["api.anthropic.com"]}' ]
}

@test "an operator who allows no egress gives a factory none, which is the opposite of a size" {
	cat >"$CAPS" <<'JSON'
{ "memory": "16G" }
JSON
	run clamped '{ "egress": ["api.anthropic.com"] }'
	[ "$output" = '{"egress":[]}' ]
}

@test "dropping an endpoint is said out loud, since a factory that reaches nothing looks broken" {
	cat >"$CAPS" <<'JSON'
{ "egress": ["api.anthropic.com"] }
JSON
	run clamp_said '{ "egress": ["api.anthropic.com", "evil.example"] }'
	[[ "$output" == *"evil.example"* ]]
}

@test "a factory that asks to reach nothing is left reaching nothing" {
	cat >"$CAPS" <<'JSON'
{ "egress": ["api.anthropic.com"] }
JSON
	run clamped '{ "cores": 2 }'
	[ "$output" = '{"cores":2}' ]
}

@test "an endpoint list that is not a list is refused rather than read as one" {
	cat >"$CAPS" <<'JSON'
{ "egress": ["api.anthropic.com"] }
JSON
	run clamp_verdict '{ "egress": "api.anthropic.com" }'
	[ "$status" -ne 0 ]
}

@test "a ceiling for endpoints that is not a list is the operator's mistake, and is refused" {
	cat >"$CAPS" <<'JSON'
{ "egress": "api.anthropic.com" }
JSON
	run clamp_verdict '{ "egress": ["api.anthropic.com"] }'
	[ "$status" -ne 0 ]
}

# ADR-070: the operator's substrate floor went with the substrate; what an
# operator may cap is what a factory may ask for, and nothing beside it.
@test "the operator caps exactly the fields a factory may ask for" {
	run fabriek_cap_field_names_json
	assert_output "$(fabriek_resource_field_names_json)"
}
