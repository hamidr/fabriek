#!/usr/bin/env bats
# What prepare renders from the declaration at boot (ADR-057 point 4): the
# bridge plan, the proxy's per-endpoint locations and ceiling, the model pi
# starts on and the models.json that points it at the proxy, and one pi
# directory per role. The build rendered every one of these into the image
# before; the same text now comes from these functions.

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/names.sh
	source "$FABRIEK_ROOT/modules/names.sh"
	# shellcheck source=../../modules/factory-render.sh
	source "$FABRIEK_ROOT/modules/factory-render.sh"
	DECL="$TEST_TEMP_DIR/declaration.json"
	ENDPOINTS="$(fabriek_render_endpoints '{}')"
	cat >"$DECL" <<'JSON'
{ "name": "acme",
  "roles": { "reviewer": { "provides": ["review"] }, "builder": { "provides": ["build"], "specialists": ["python"] } },
  "resources": { "egress": ["api.anthropic.com", "api.deepseek.com"], "tokens": 500000 } }
JSON
}

teardown() {
	teardown_temp_dir
}

@test "the bridge plan puts the machine at .1, the decider at .2 and the roles from .10 in name order" {
	run fabriek_render_bridge_plan "$DECL" fabriek0 10.77.0.1 8118 3000 4222
	assert_success
	run jq -c '[.bridge, .host, .prefix, .cages, .proxy, .forgejo, .bus]' <<<"$output"
	assert_output '["fabriek0","10.77.0.1",24,{"builder":"10.77.0.10","decider":"10.77.0.2","reviewer":"10.77.0.11"},"10.77.0.1:8118","10.77.0.1:3000","10.77.0.1:4222"]'
}

@test "nothing here names a cage's veth: the bridge's rules are nixcage's, keyed on nothing rendered here" {
	# ADR-064: the set the plan used to fill is gone with the verb that named
	# its elements, so a change to nixcage's hash cannot leave a rule here
	# matching nothing.
	run grep -c 'nixcage-container veth\|fabriek_render_cage_elements' "$FABRIEK_ROOT/modules/factory-render.sh" "$FABRIEK_ROOT/fabriek-container"
	refute_output --partial ':1'
	refute_output --partial ':2'
}

@test "the proxy gets the ceiling and one location per allowed endpoint, counting and refusing at the ceiling" {
	run fabriek_render_proxy "$DECL"
	assert_success
	assert_line --index 0 'set $spend_ceiling 500000;'
	assert_output --partial 'location /api.anthropic.com/ {'
	assert_output --partial 'proxy_pass https://api.anthropic.com/;'
	assert_output --partial 'include /run/fabriek-egress/acme/api.anthropic.com.conf;'
	assert_output --partial 'location /api.deepseek.com/ {'
	assert_output --partial 'js_body_filter spend.count;'
	assert_output --partial 'return 429;'
	refute_output --partial 'api.openai.com'
}

# pi sends its placeholder key as x-api-key to an anthropic-api endpoint. An
# endpoint whose credential travels in another header would receive both,
# and a gateway may refuse the placeholder before it reads the real one.
@test "the proxy clears the placeholder x-api-key where the credential travels in another header" {
	jq '.resources.egress = ["api.anthropic.com", "gw.example.test", "api.deepseek.com"]' "$DECL" >"$DECL.2"
	run fabriek_render_proxy "$DECL.2" '{"api.anthropic.com":"x-api-key","gw.example.test":"Authorization"}'
	assert_success
	run awk '/^location \/gw.example.test\//,/^}/' <<<"$output"
	assert_output --partial 'proxy_set_header x-api-key "";'
	run fabriek_render_proxy "$DECL.2" '{"api.anthropic.com":"x-api-key","gw.example.test":"Authorization"}'
	run awk '/^location \/api.anthropic.com\//,/^}/' <<<"$output"
	refute_output --partial 'proxy_set_header x-api-key'
	run awk '/^location \/api.deepseek.com\//,/^}/' <<<"$(fabriek_render_proxy "$DECL.2" '{"api.anthropic.com":"x-api-key","gw.example.test":"Authorization"}')"
	refute_output --partial 'proxy_set_header x-api-key'
}

@test "with no endpoint allowed the proxy gets the ceiling and no location" {
	jq '.resources.egress = []' "$DECL" >"$DECL.2"
	run fabriek_render_proxy "$DECL.2"
	assert_success
	assert_output 'set $spend_ceiling 500000;'
}

@test "the model a session starts on is the operator's for the first routed endpoint, else fabriek's table" {
	run fabriek_render_model "$DECL" '{"api.anthropic.com": "claude-opus-5"}' "$ENDPOINTS"
	assert_success
	assert_output '{"model":"claude-opus-5","provider":"anthropic"}'
	run fabriek_render_model "$DECL" '{}' "$ENDPOINTS"
	assert_output '{"model":"claude-sonnet-4-5","provider":"anthropic"}'
	jq '.resources.egress = ["api.deepseek.com"]' "$DECL" >"$DECL.2"
	run fabriek_render_model "$DECL.2" '{}' "$ENDPOINTS"
	assert_output '{"model":"deepseek-v4-flash","provider":"deepseek"}'
}

@test "models.json points each routed provider at its path on the proxy with a placeholder key" {
	run fabriek_render_models "$DECL" 10.77.0.1:8118 "$ENDPOINTS"
	assert_success
	assert_output '{"providers":{"anthropic":{"apiKey":"fabriek","baseUrl":"http://10.77.0.1:8118/api.anthropic.com"},"deepseek":{"apiKey":"fabriek","baseUrl":"http://10.77.0.1:8118/api.deepseek.com"}}}'
}

# An endpoint the operator declares (ADR-072): the shipped three are the
# table's defaults and a declared host is one more row, answered by a pi
# provider with the compat the endpoint needs.
@test "an operator-declared endpoint is routed through the proxy with its compat" {
	local decl="$TEST_TEMP_DIR/gateway.json" table
	jq '.resources.egress = ["gw.example.test"]' "$DECL" >"$decl"
	table="$(fabriek_render_endpoints '{"gw.example.test":{"provider":"anthropic","compat":{"supportsStrictTools":false}}}')"
	run fabriek_render_models "$decl" 10.77.0.1:8118 "$table"
	assert_success
	assert_output '{"providers":{"anthropic":{"apiKey":"fabriek","baseUrl":"http://10.77.0.1:8118/gw.example.test","compat":{"supportsStrictTools":false}}}}'
	run fabriek_render_model "$decl" '{"gw.example.test":"claude-sonnet-5"}' "$table"
	assert_success
	assert_output '{"model":"claude-sonnet-5","provider":"anthropic"}'
}

@test "an operator-declared endpoint names its api when it is not the provider's own" {
	local decl="$TEST_TEMP_DIR/gateway.json" table
	jq '.resources.egress = ["gw.example.test"]' "$DECL" >"$decl"
	table="$(fabriek_render_endpoints '{"gw.example.test":{"provider":"anthropic","api":"anthropic-messages"}}')"
	run fabriek_render_models "$decl" 10.77.0.1:8118 "$table"
	assert_success
	assert_output --partial '"api":"anthropic-messages"'
}

@test "an operator-declared endpoint with no model is refused by name" {
	local decl="$TEST_TEMP_DIR/gateway.json" table
	jq '.resources.egress = ["gw.example.test"]' "$DECL" >"$decl"
	table="$(fabriek_render_endpoints '{"gw.example.test":{"provider":"anthropic"}}')"
	run fabriek_render_model "$decl" '{}' "$table"
	assert_failure
	assert_output --partial 'gw.example.test'
	assert_output --partial 'no model'
}

@test "two allowed endpoints answering as one provider are refused" {
	local decl="$TEST_TEMP_DIR/gateway.json" table
	jq '.resources.egress = ["api.anthropic.com", "gw.example.test"]' "$DECL" >"$decl"
	table="$(fabriek_render_endpoints '{"gw.example.test":{"provider":"anthropic"}}')"
	run fabriek_render_models "$decl" 10.77.0.1:8118 "$table"
	assert_failure
	assert_output --partial 'provider anthropic'
}

@test "an operator entry for a shipped host changes the fields it names and keeps the model" {
	local table
	table="$(fabriek_render_endpoints '{"api.anthropic.com":{"compat":{"supportsStrictTools":false}}}')"
	run jq -c '.["api.anthropic.com"]' <<<"$table"
	assert_output '{"provider":"anthropic","model":"claude-sonnet-4-5","compat":{"supportsStrictTools":false}}'
}

# A role names a model, and only by a name the operator's endpoint lists
# (ADR-072 point 2): the role's own, else its specialist's, else the
# endpoint's default.
role_model_json() {
	printf '%s' '{"model":"m-default","provider":"anthropic","models":{"default":"m-default","opus":"m-opus","fast":"m-fast"}}' >"$TEST_TEMP_DIR/model.json"
	jq '.roles.builder.model = "opus"' "$DECL" >"$DECL.2"
}

@test "a role model beats its specialist's, which beats the endpoint's default" {
	role_model_json
	run fabriek_render_role_model "$DECL.2" "$TEST_TEMP_DIR/model.json" builder fast
	assert_success
	assert_output m-opus
	run fabriek_render_role_model "$DECL" "$TEST_TEMP_DIR/model.json" builder fast
	assert_output m-fast
	run fabriek_render_role_model "$DECL" "$TEST_TEMP_DIR/model.json" builder ""
	assert_output m-default
}

@test "a role model the endpoint does not list is refused by role and name" {
	role_model_json
	jq '.roles.builder.model = "huge"' "$DECL" >"$DECL.2"
	run fabriek_render_role_model "$DECL.2" "$TEST_TEMP_DIR/model.json" builder ""
	assert_failure
	assert_output --partial "role builder"
	assert_output --partial "huge"
	run fabriek_render_role_model "$DECL" "$TEST_TEMP_DIR/model.json" builder huge
	assert_failure
	assert_output --partial "huge"
}

@test "a role model on an endpoint that lists no names is refused" {
	printf '%s' '{"model":"claude-sonnet-4-5","provider":"anthropic"}' >"$TEST_TEMP_DIR/model.json"
	jq '.roles.builder.model = "opus"' "$DECL" >"$DECL.2"
	run fabriek_render_role_model "$DECL.2" "$TEST_TEMP_DIR/model.json" builder ""
	assert_failure
	assert_output --partial "lists no model names"
}

@test "the model a session starts on carries the endpoint's model names when it lists some" {
	local decl="$TEST_TEMP_DIR/gateway.json" table
	jq '.resources.egress = ["gw.example.test"]' "$DECL" >"$decl"
	table="$(fabriek_render_endpoints '{"gw.example.test":{"provider":"anthropic","models":{"default":"m","opus":"o"}}}')"
	run fabriek_render_model "$decl" '{"gw.example.test":"m"}' "$table"
	assert_success
	assert_output '{"model":"m","provider":"anthropic","models":{"default":"m","opus":"o"}}'
}

# The floor is what the image carries for every role (ADR-030): the loop and
# the two extensions' index files, and the guidance. A role's directory is
# the floor plus what its profile says it is.
@test "a role's pi directory is the floor's extensions, its profile's kit by link, and the guidance in front of its prompt" {
	local floor="$TEST_TEMP_DIR/floor" profile="$TEST_TEMP_DIR/profile" out="$TEST_TEMP_DIR/pi"
	mkdir -p "$floor/extensions/fabriek" "$floor/extensions/pi-lsp" "$floor/extensions/pi-codegraph"
	echo 'export { default } from "/nix/store/x-loop/index.js";' >"$floor/extensions/fabriek/index.ts"
	echo 'lsp' >"$floor/extensions/pi-lsp/index.ts"
	echo 'cg' >"$floor/extensions/pi-codegraph/index.ts"
	echo '# Working as a factory role' >"$floor/guidance.md"
	mkdir -p "$profile/share/fabriek/specialist/skills/python"
	echo '{"servers":[]}' >"$profile/share/fabriek/specialist/lsp.json"
	echo '{"files":[]}' >"$profile/share/fabriek/specialist/tests.json"
	echo '## python' >"$profile/share/fabriek/specialist/APPEND_SYSTEM.md"
	run fabriek_render_pi_dir "$floor" "$profile" '{"providers":{}}' "$out"
	assert_success
	[ -f "$out/extensions/fabriek/index.ts" ]
	[ -f "$out/extensions/pi-lsp/index.ts" ]
	[ -f "$out/extensions/pi-codegraph/index.ts" ]
	[ "$(readlink "$out/lsp.json")" = "$profile/share/fabriek/specialist/lsp.json" ]
	[ "$(readlink "$out/tests.json")" = "$profile/share/fabriek/specialist/tests.json" ]
	[ "$(readlink "$out/skills")" = "$profile/share/fabriek/specialist/skills" ]
	run cat "$out/APPEND_SYSTEM.md"
	assert_line --index 0 '# Working as a factory role'
	assert_line --index 1 '## python'
	run cat "$out/models.json"
	assert_output '{"providers":{}}'
}

@test "rendering a role's pi directory twice leaves one directory, not a nest" {
	local floor="$TEST_TEMP_DIR/floor" profile="$TEST_TEMP_DIR/profile" out="$TEST_TEMP_DIR/pi"
	mkdir -p "$floor/extensions/fabriek" "$profile/share/fabriek/specialist/skills"
	echo loop >"$floor/extensions/fabriek/index.ts"
	echo g >"$floor/guidance.md"
	: >"$profile/share/fabriek/specialist/lsp.json"
	: >"$profile/share/fabriek/specialist/tests.json"
	: >"$profile/share/fabriek/specialist/APPEND_SYSTEM.md"
	fabriek_render_pi_dir "$floor" "$profile" '{}' "$out"
	fabriek_render_pi_dir "$floor" "$profile" '{}' "$out"
	[ ! -e "$out/skills/skills" ]
	[ "$(readlink "$out/skills")" = "$profile/share/fabriek/specialist/skills" ]
}

@test "the decider's directory is the floor's decider loop and the same models.json" {
	local floor="$TEST_TEMP_DIR/floor" out="$TEST_TEMP_DIR/pi-decider"
	mkdir -p "$floor/decider/extensions/fabriek"
	echo 'decider loop' >"$floor/decider/extensions/fabriek/index.ts"
	run fabriek_render_decider_dir "$floor" '{"providers":{}}' "$out"
	assert_success
	run cat "$out/extensions/fabriek/index.ts"
	assert_output 'decider loop'
	run cat "$out/models.json"
	assert_output '{"providers":{}}'
}

# Two factories on one host each have an egress-credentials unit writing
# under /run/fabriek-egress/<factory>/; a location including the flat path
# reads nothing on a host with one factory and the wrong factory's header on
# a host with two.
@test "a location includes the credential the factory's own unit writes, never another factory's" {
	run fabriek_render_proxy "$DECL"
	assert_success
	refute_output --partial 'include /run/fabriek-egress/api.anthropic.com.conf;'
	assert_output --partial 'include /run/fabriek-egress/acme/api.anthropic.com.conf;'
}

# Each factory on a host has a bridge of its own with its own net (ADR-067
# point 3), and the host writes the bridge's address in the facts. Found on
# pc 2026-09-22: the second factory's plan named the first's net, so both
# factories' services and cages were planned on one bridge and the second's
# bus ACL hit the first's bus.
@test "the bridge plan is laid on the bridge's own net, taken from the address the host gave it" {
	run fabriek_render_bridge_plan "$DECL" fb-1 10.77.1.1 8118 3000 4222
	assert_success
	run jq -c '[.bridge, .host, .cages.decider, .cages.builder, .bus]' <<<"$output"
	assert_output '["fb-1","10.77.1.1","10.77.1.2","10.77.1.10","10.77.1.1:4222"]'
}

@test "a declaration with more roles than the subnet has addresses below the machine's is refused" {
	# .254 is the factory's machine's own address on its bridge (ADR-070),
	# so the last a role may take is .253: 244 roles from .10.
	jq -n '{ name: "acme", roles: ([range(0; 245)] | map({ key: "r\(.)", value: {} }) | from_entries) }' >"$TEST_TEMP_DIR/many.json"
	run fabriek_render_bridge_plan "$TEST_TEMP_DIR/many.json" fb-0 10.77.0.1 8118 3000 4222
	assert_failure
	assert_output --partial "245 roles; a factory's bridge holds 244"
	jq -n '{ name: "acme", roles: ([range(0; 244)] | map({ key: "r\(.)", value: {} }) | from_entries) }' >"$TEST_TEMP_DIR/many.json"
	run fabriek_render_bridge_plan "$TEST_TEMP_DIR/many.json" fb-0 10.77.0.1 8118 3000 4222
	assert_success
	refute_output --partial '10.77.0.254'
}
