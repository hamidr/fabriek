#!/usr/bin/env bats
# What prepare renders from the declaration at boot (ADR-057 point 4): the
# bridge plan and the set elements the bridge's rules key on, the proxy's
# per-endpoint locations and ceiling, the model pi starts on and the
# models.json that points it at the proxy, and one pi directory per role.
# The build rendered every one of these into the image before; the same
# text now comes from these functions, driven here with nixcage-container
# stubbed for the veth's name.

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/names.sh
	source "$FABRIEK_ROOT/modules/names.sh"
	# shellcheck source=../../modules/factory-render.sh
	source "$FABRIEK_ROOT/modules/factory-render.sh"
	mkdir -p "$TEST_TEMP_DIR/bin"
	# nixcage names a veth from a hash of the cage's name; the stub makes
	# the name legible so the assertion reads.
	printf '#!/usr/bin/env bash\n[ "$1" = veth ] && echo "nc-$2"\n' >"$TEST_TEMP_DIR/bin/nixcage-container"
	chmod +x "$TEST_TEMP_DIR/bin/nixcage-container"
	export PATH="$TEST_TEMP_DIR/bin:$PATH"
	DECL="$TEST_TEMP_DIR/declaration.json"
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
	run fabriek_render_bridge_plan "$DECL" fabriek0 8118 3000 6379
	assert_success
	run jq -c '[.bridge, .host, .prefix, .cages, .proxy, .forgejo, .valkey]' <<<"$output"
	assert_output '["fabriek0","10.77.0.1",24,{"builder":"10.77.0.10","decider":"10.77.0.2","reviewer":"10.77.0.11"},"10.77.0.1:8118","10.77.0.1:3000","10.77.0.1:6379"]'
}

@test "the cages set is one element per cage, the veth nixcage names beside the address" {
	fabriek_render_bridge_plan "$DECL" fabriek0 8118 3000 6379 >"$TEST_TEMP_DIR/plan.json"
	run fabriek_render_cage_elements "$TEST_TEMP_DIR/plan.json"
	assert_success
	assert_output '"nc-builder" . 10.77.0.10, "nc-decider" . 10.77.0.2, "nc-reviewer" . 10.77.0.11'
}

@test "the proxy gets the ceiling and one location per allowed endpoint, counting and refusing at the ceiling" {
	run fabriek_render_proxy "$DECL"
	assert_success
	assert_line --index 0 'set $spend_ceiling 500000;'
	assert_output --partial 'location /api.anthropic.com/ {'
	assert_output --partial 'proxy_pass https://api.anthropic.com/;'
	assert_output --partial 'include /run/fabriek-egress/api.anthropic.com.conf;'
	assert_output --partial 'location /api.deepseek.com/ {'
	assert_output --partial 'js_body_filter spend.count;'
	assert_output --partial 'return 429;'
	refute_output --partial 'api.openai.com'
}

@test "with no endpoint allowed the proxy gets the ceiling and no location" {
	jq '.resources.egress = []' "$DECL" >"$DECL.2"
	run fabriek_render_proxy "$DECL.2"
	assert_success
	assert_output 'set $spend_ceiling 500000;'
}

@test "the model a session starts on is the operator's for the first routed endpoint, else fabriek's table" {
	run fabriek_render_model "$DECL" '{"api.anthropic.com": "claude-opus-5"}'
	assert_success
	assert_output '{"model":"claude-opus-5","provider":"anthropic"}'
	run fabriek_render_model "$DECL" '{}'
	assert_output '{"model":"claude-sonnet-4-5","provider":"anthropic"}'
	jq '.resources.egress = ["api.deepseek.com"]' "$DECL" >"$DECL.2"
	run fabriek_render_model "$DECL.2" '{}'
	assert_output '{"model":"deepseek-v4-flash","provider":"deepseek"}'
}

@test "models.json points each routed provider at its path on the proxy with a placeholder key" {
	run fabriek_render_models "$DECL" 10.77.0.1:8118
	assert_success
	assert_output '{"providers":{"anthropic":{"apiKey":"fabriek","baseUrl":"http://10.77.0.1:8118/api.anthropic.com"},"deepseek":{"apiKey":"fabriek","baseUrl":"http://10.77.0.1:8118/api.deepseek.com"}}}'
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
