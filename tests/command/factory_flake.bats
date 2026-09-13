#!/usr/bin/env bats
# One factory's machine from the repository it works (ADR-040): lib.factory,
# evaluated for real against a repository that declares a factory. The spec
# derivation is built, because import from derivation is the mechanism; the
# machine is only evaluated, because building one is a proof's job.

load ../test_helper/common

setup() {
	setup_temp_dir
	HOST="$(nix eval --impure --raw --expr 'builtins.currentSystem')"
	MACHINE="${HOST%%-*}-linux"
	REPO="$TEST_TEMP_DIR/acme"
	mkdir -p "$REPO"
	git init -q "$REPO"
	git -C "$REPO" config user.name factory
	git -C "$REPO" config user.email factory@invalid
	declare_flake "devShells.$MACHINE.backend = { buildInputs = [ ]; };"
	cat >"$TEST_TEMP_DIR/local.json" <<JSON
{ "factory": "acme", "system": "$MACHINE", "hostSystem": "$HOST",
  "sshPort": 2222, "authorizedKey": "ssh-ed25519 AAAA acme",
  "caps": { "memory": "16G", "cores": 2, "egress": ["api.anthropic.com"] },
  "credentials": { "api.anthropic.com": "x-api-key" } }
JSON
}

teardown() {
	teardown_temp_dir
}

## A repository flake declaring acme, with whatever extra outputs a scenario
## needs, committed because that is what is read.
declare_flake() {
	cat >"$REPO/flake.nix" <<NIX
{
  outputs = { self }: {
    cageworks = {
      name = "acme";
      roles.builder = { command = [ "claude" ]; provides = [ "build" ]; shell = "backend"; };
      roles.reviewer = { command = [ "claude" ]; provides = [ "review" ]; };
      workflows.ship.stages = [ { needs = "build"; } { needs = "review"; } ];
      resources = { memory = "4G"; cores = 12; egress = [ "api.anthropic.com" "api.openai.com" ]; };
    };
    $1
  };
}
NIX
	git -C "$REPO" add -A
	git -C "$REPO" -c commit.gpgsign=false commit -qm declare
}

## Evaluate one attribute of lib.factory for this repository, as JSON. nix
## warns about an absent channel path on every impure evaluation and says
## "building" when the spec derivation is not cached; both are noise on lines
## the scenarios read, so they are dropped.
factory_eval() {
	nix eval --json --impure --expr "
	  ((builtins.getFlake \"path:$CAGEWORKS_ROOT\").lib.factory {
	    project = builtins.getFlake \"git+file://$REPO\";
	    local = $TEST_TEMP_DIR/local.json;
	  })$1" 2> >(grep -v -e 'Nix search path entry' -e "^building '" >&2)
}

@test "given a repository that declares a factory, the spec is composed in a build from the pinned declaration" {
	run factory_eval '.spec'
	assert_success
	run jq -c '{cpus, mem, egress, headers: .egressHeaders}' <<<"$output"
	assert_success
	assert_output '{"cpus":2,"mem":4096,"egress":["api.anthropic.com"],"headers":{"api.anthropic.com":"x-api-key"}}'
}

@test "what the build clamped is in the spec for the operator" {
	run factory_eval '.spec.notes'
	assert_success
	assert_output --partial "api.openai.com"
	assert_output --partial "cores asked for 12"
}

@test "a role's devShell is realised into a profile, and a role naming none gets an empty one" {
	run factory_eval '.profiles.builder.name'
	assert_success
	assert_output '"cageworks-role-builder"'
	run factory_eval '.profiles.reviewer.name'
	assert_success
	assert_output '"cageworks-role-reviewer"'
}

# stdenv hands a shell its inputs as dev outputs (headers, curl-config), and
# a profile made of those has no ip and no curl in it; found on a machine
# whose every role lacked the tools its shell named. What a cage runs is
# the bin output.
@test "a role's profile is made of its tools' bin outputs, not the dev outputs stdenv hands a shell" {
	declare_flake "devShells.$MACHINE.backend = { nativeBuildInputs = [ {
	    outPath = \"/nix/store/00000000000000000000000000000000-curl-dev\";
	    outputSpecified = true;
	    bin = { outPath = \"/nix/store/00000000000000000000000000000000-curl-bin\"; };
	  } ]; };"
	run factory_eval '.profiles.builder.paths'
	assert_success
	assert_output --partial 'curl-bin'
	refute_output --partial 'curl-dev'
}

@test "when a role names a devShell the repository does not define, the build fails naming the role" {
	declare_flake ''
	run factory_eval '.profiles.builder.name'
	assert_failure
	assert_output --partial "role builder names devShell backend"
}

@test "when the repository declares no factory, the build says so" {
	printf '{ outputs = { self }: { }; }\n' >"$REPO/flake.nix"
	git -C "$REPO" add -A
	git -C "$REPO" -c commit.gpgsign=false commit -qm undeclare
	run factory_eval '.spec.factory'
	assert_failure
	assert_output --partial "declares no factory"
}

@test "when the declaration carries a key cageworks does not know, the build fails by that key's name" {
	declare_flake "devShells.$MACHINE.backend = { buildInputs = [ ]; }; cageworks.roles.builder.colour = \"blue\";"
	run factory_eval '.spec.factory'
	assert_failure
	assert_output --partial "colour"
}

@test "the machine carries the clamped declaration as a file the machine reads instead of evaluating" {
	run factory_eval '.config.environment.etc."cageworks/declaration.json".text'
	assert_success
	run jq -r '.resources.cores, (.resources.egress | length)' <<<"$(printf '%s' "$output" | jq -r .)"
	assert_line --index 0 2
	assert_line --index 1 1
}
