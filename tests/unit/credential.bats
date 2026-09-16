#!/usr/bin/env bats
# The credential a machine boots with (ADR-057 point 3): the operator's
# config.toml projected for one factory, plus the pin. Written by the host
# side of up; read on the machine by the one TOML reader, so what is written
# here is checked by reading it back the way the machine will.

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/names.sh
	source "$FABRIEK_ROOT/modules/names.sh"
	# shellcheck source=../../modules/repo-declaration.sh
	source "$FABRIEK_ROOT/modules/repo-declaration.sh"
	# shellcheck source=../../modules/credential.sh
	source "$FABRIEK_ROOT/modules/credential.sh"
	CONFIG="$TEST_TEMP_DIR/config.json"
	cat >"$CONFIG" <<'JSON'
{ "caps": { "memory": "16G", "cores": 8, "recordQuota": "8G", "tokens": 1000000, "egress": ["api.anthropic.com"] },
  "factories": { "acme": { "path": "/home/me/Src/acme" } },
  "credentials": { "api.anthropic.com": { "header": "x-api-key", "file": "/run/secrets/anthropic" } },
  "models": { "api.anthropic.com": "claude-opus-5" },
  "embedder": { "url": "http://127.0.0.1:8080" } }
JSON
}

teardown() {
	teardown_temp_dir
}

@test "the credential carries the factory, the pin, the caps, the headers, the models and the embedder, and never a secret's value or path" {
	run fabriek_credential_toml "$CONFIG" acme "git+file:///home/me/Src/acme" 3f1c2ab9e0d4b6c7f8a9e1d2c3b4a5f6e7d8c9b0 x86_64-linux
	assert_success
	printf '%s\n' "$output" >"$TEST_TEMP_DIR/fabriek.toml"
	run fabriek_toml_json "$TEST_TEMP_DIR/fabriek.toml"
	assert_success
	run jq -cS . <<<"$output"
	assert_output '{"caps":{"cores":8,"egress":["api.anthropic.com"],"memory":"16G","recordQuota":"8G","tokens":1000000},"catalogues":[],"credentials":{"api.anthropic.com":"x-api-key"},"embedder":{"url":"http://127.0.0.1:8080"},"factory":{"hostSystem":"x86_64-linux","name":"acme"},"models":{"api.anthropic.com":"claude-opus-5"},"pin":{"rev":"3f1c2ab9e0d4b6c7f8a9e1d2c3b4a5f6e7d8c9b0"},"repository":{"path":"/home/me/Src/acme","remote":"git+file:///home/me/Src/acme"},"skills":{},"specialists":{}}'
	run grep -c "/run/secrets" "$TEST_TEMP_DIR/fabriek.toml"
	assert_output 0
}

@test "an operator holding no credentials, models or embedder writes those tables empty, and the reader accepts it" {
	jq 'del(.credentials, .models, .embedder)' "$CONFIG" >"$CONFIG.2"
	run fabriek_credential_toml "$CONFIG.2" acme "git+file:///home/me/Src/acme" abc123 x86_64-linux
	assert_success
	printf '%s\n' "$output" >"$TEST_TEMP_DIR/fabriek.toml"
	run fabriek_toml_json "$TEST_TEMP_DIR/fabriek.toml"
	assert_success
	run jq -c '[.credentials, .models, .embedder]' <<<"$output"
	assert_output '[{},{},null]'
}

@test "the pin is read back and moved in place, leaving every other line as it was" {
	fabriek_credential_toml "$CONFIG" acme "git+file:///home/me/Src/acme" aaaa x86_64-linux >"$TEST_TEMP_DIR/fabriek.toml"
	run fabriek_credential_rev "$TEST_TEMP_DIR/fabriek.toml"
	assert_output aaaa
	fabriek_credential_pin "$TEST_TEMP_DIR/fabriek.toml" bbbb
	run fabriek_credential_rev "$TEST_TEMP_DIR/fabriek.toml"
	assert_output bbbb
	run fabriek_toml_json "$TEST_TEMP_DIR/fabriek.toml"
	run jq -r '.caps.memory' <<<"$output"
	assert_output 16G
}

# ADR-061 point 6: a factory declared in the operator's file, and the
# operator's specialists, skills and catalogue directories, travel to the
# machine in the credential, as TOML the same reader takes back whole.
@test "the credential carries the operator's declaration, specialists, skills and catalogues, read back as written" {
	jq '.factories.acme += {
	      "roles": { "backend": { "provides": ["build"], "specialists": ["rust"], "replicas": 2 } },
	      "workflows": { "ship": { "stages": [ { "needs": "build", "done": "tests pass", "ready": ["acceptance"] }, { "needs": "review", "verdict": true } ],
	                              "budget": { "runs": 200 }, "consults": { "backend": ["architect"] } } },
	      "resources": { "memory": "8G", "cores": 4 },
	      "decider": { "policy": "docs/policy.md" } }
	    | .specialists = { "rust": { "extends": ["developer"], "tools": ["cargo"], "skills": ["cargo-profile"], "prompt": "/nix/store/aaaa-rust.md" } }
	    | .skills = { "cargo-profile": { "tools": ["cargo"], "skill": "You profile.\nTwice.\n" } }
	    | .catalogues = ["/nix/store/bbbb-catalogue"]' "$CONFIG" >"$CONFIG.3"
	run fabriek_credential_toml "$CONFIG.3" acme "git+file:///home/me/Src/acme" abc123 x86_64-linux
	assert_success
	printf '%s\n' "$output" >"$TEST_TEMP_DIR/fabriek.toml"
	run fabriek_toml_json "$TEST_TEMP_DIR/fabriek.toml"
	assert_success
	run jq -cS '{declaration, specialists, skills, catalogues}' <<<"$output"
	assert_output "$(jq -cS '{declaration: (.factories.acme | del(.path) | . + {name: "acme"}), specialists, skills, catalogues}' "$CONFIG.3")"
}

@test "a factory declared in the repository puts no declaration table in the credential" {
	run fabriek_credential_toml "$CONFIG" acme "git+file:///home/me/Src/acme" abc123 x86_64-linux
	assert_success
	printf '%s\n' "$output" >"$TEST_TEMP_DIR/fabriek.toml"
	run fabriek_toml_json "$TEST_TEMP_DIR/fabriek.toml"
	run jq -c '[.declaration, .specialists, .skills, .catalogues]' <<<"$output"
	assert_output '[null,{},{},[]]'
}
