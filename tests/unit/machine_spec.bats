#!/usr/bin/env bats
# The spec a factory's machine is built from, composed where the build runs
# rather than where the operator types (ADR-040). One function, two files in:
# the declaration as the repository's flake evaluated it, and the local facts
# the operator's host knows (port, key, ceilings, credential headers). One
# JSON document out, or a refusal naming what was wrong.

load ../test_helper/common

setup() {
	setup_temp_dir
	for m in names sizes schema resources repo-declaration machine-spec; do
		# shellcheck disable=SC1090
		source "$FABRIEK_ROOT/modules/$m.sh"
	done
	DECL="$TEST_TEMP_DIR/declaration.json"
	LOCAL="$TEST_TEMP_DIR/local.json"
	cat >"$DECL" <<'JSON'
{ "name": "acme",
  "roles": { "builder": { "command": ["claude"], "provides": ["build"], "shell": "backend" } },
  "workflows": { "ship": { "stages": [ { "needs": "build" } ] } },
  "resources": { "memory": "4G", "cores": 12,
                 "egress": ["api.anthropic.com", "api.openai.com"] } }
JSON
	cat >"$LOCAL" <<'JSON'
{ "factory": "acme", "system": "aarch64-linux", "hostSystem": "aarch64-darwin",
  "sshPort": 2222, "authorizedKey": "ssh-ed25519 AAAA acme",
  "caps": { "memory": "16G", "cores": 8, "egress": ["api.anthropic.com"] },
  "credentials": { "api.anthropic.com": "x-api-key", "api.other.com": "authorization" },
  "models": { "api.anthropic.com": "claude-opus-5", "api.openai.com": "gpt-5" } }
JSON
}

teardown() {
	teardown_temp_dir
}

spec() { fabriek_machine_spec "$DECL" "$LOCAL" 2>/dev/null; }

@test "given a declaration and the local facts, the spec names the factory, its port and its key" {
	run jq -r '.factory, .system, .hostSystem, .sshPort, .authorizedKey' <<<"$(spec)"
	assert_success
	assert_line --index 0 acme
	assert_line --index 1 aarch64-linux
	assert_line --index 2 aarch64-darwin
	assert_line --index 3 2222
	assert_line --index 4 "ssh-ed25519 AAAA acme"
}

@test "when the factory asks for more than the operator allows, the spec carries the ceiling, in MiB" {
	run jq -r '.cpus, .mem' <<<"$(spec)"
	assert_line --index 0 8
	assert_line --index 1 4096
}

@test "egress is what the operator allowed, and a header only for an endpoint that has a credential" {
	run jq -c '.egress, .egressHeaders' <<<"$(spec)"
	assert_line --index 0 '["api.anthropic.com"]'
	assert_line --index 1 '{"api.anthropic.com":"x-api-key"}'
}

@test "the model the operator named rides in the spec only for an endpoint the factory reaches" {
	run jq -c '.egressModels' <<<"$(spec)"
	assert_output '{"api.anthropic.com":"claude-opus-5"}'
}

@test "a named endpoint in a declaration's egress is its host before the clamp, and rides in the spec with its row" {
	jq '.resources.egress = ["zd-gateway"]' "$DECL" >"$DECL.new" && mv "$DECL.new" "$DECL"
	jq '.caps.egress = ["gw.example.test"] | .names = {"zd-gateway": "gw.example.test"}
	  | .credentials = {"gw.example.test": "Authorization"}
	  | .endpoints = {"gw.example.test": {"provider": "anthropic", "models": {"default": "m"}}}' "$LOCAL" >"$LOCAL.new" && mv "$LOCAL.new" "$LOCAL"
	run jq -cS '.egress, .egressHeaders, .egressEndpoints, .declaration.resources.egress' <<<"$(spec)"
	assert_line --index 0 '["gw.example.test"]'
	assert_line --index 1 '{"gw.example.test":"Authorization"}'
	assert_line --index 2 '{"gw.example.test":{"models":{"default":"m"},"provider":"anthropic"}}'
	assert_line --index 3 '["gw.example.test"]'
}

@test "a named endpoint rides in the spec only for an endpoint the factory reaches" {
	jq '.endpoints = {"api.anthropic.com": {"compat": {"supportsStrictTools": false}}, "gw.example.test": {"provider": "anthropic"}}' "$LOCAL" >"$LOCAL.new" && mv "$LOCAL.new" "$LOCAL"
	run jq -c '.egressEndpoints' <<<"$(spec)"
	assert_output '{"api.anthropic.com":{"compat":{"supportsStrictTools":false}}}'
}

@test "the spec carries the clamped declaration, so the machine reads it from a file and never evaluates it" {
	run jq -r '.declaration.resources.cores, .declaration.roles.builder.shell, (.declaration.resources.egress | length)' <<<"$(spec)"
	assert_line --index 0 8
	assert_line --index 1 backend
	assert_line --index 2 1
}

@test "when the declaration carries a key fabriek does not know, the build is refused by that key's name" {
	jq '.roles.builder.colour = "blue"' "$DECL" >"$DECL.new" && mv "$DECL.new" "$DECL"
	run fabriek_machine_spec "$DECL" "$LOCAL"
	assert_failure
	assert_output --partial colour
}

@test "when a stage needs what no role provides, the build is refused" {
	jq '.workflows.ship.stages[0].needs = "review"' "$DECL" >"$DECL.new" && mv "$DECL.new" "$DECL"
	run fabriek_machine_spec "$DECL" "$LOCAL"
	assert_failure
	assert_output --partial review
}

@test "a cage told nothing about memory gets no number, and keeps its own default" {
	jq 'del(.resources.memory)' "$DECL" >"$DECL.new" && mv "$DECL.new" "$DECL"
	run jq -c '[has("mem")]' <<<"$(spec)"
	assert_output '[false]'
}

@test "what the clamp changed rides in the spec, because a build's log is not where an operator looks" {
	run jq -r '.notes | join("; ")' <<<"$(spec)"
	assert_output --partial "cores asked for 12"
	assert_output --partial "api.openai.com"
}
