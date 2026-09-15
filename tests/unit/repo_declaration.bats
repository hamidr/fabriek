#!/usr/bin/env bats
# The factory a repository declares about itself (ADR-020).
#
# Validation is pure: JSON in, either normalised JSON out or a message naming
# what was wrong. Reading is the only part that needs nix and a git repository,
# and it is separated so that the schema can be tested without either.

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/names.sh
	source "$FABRIEK_ROOT/modules/names.sh"
	# shellcheck source=../../modules/schema.sh
	source "$FABRIEK_ROOT/modules/schema.sh"
	# shellcheck source=../../modules/resources.sh
	source "$FABRIEK_ROOT/modules/resources.sh"
	# shellcheck source=../../modules/repo-declaration.sh
	source "$FABRIEK_ROOT/modules/repo-declaration.sh"
}

teardown() {
	teardown_temp_dir
}

## A declaration somebody would actually write. Every test starts here and
## changes one thing, so what a test is about is exactly what it edits.
complete_declaration() {
	cat <<'JSON'
{
  "name": "acme",
  "roles": {
    "architect": { "command": ["claude"], "provides": ["design"] },
    "backend": {
      "command": ["claude"],
      "provides": ["build"],
      "shell": "backend-jvm"
    }
  },
  "workflows": {
    "ship": {
      "stages": [
        { "needs": "design", "done": "the approach is written down" },
        { "needs": "build", "ready": ["acceptance"], "done": "tests pass" }
      ],
      "budget": { "runs": 200 },
      "consults": { "backend": ["architect"] }
    }
  },
  "resources": {
    "memory": "8G",
    "cores": 4,
    "roleQuota": "20G",
    "concurrency": 3
  }
}
JSON
}

## Validate the complete declaration with one jq edit applied to it.
validate_with() {
	complete_declaration | jq "$@" | fabriek_declaration_validate
}

@test "a complete declaration is accepted and comes back as itself" {
	run validate_with '.'
	assert_success
	assert_output --partial '"name"'
	assert_output --partial 'acme'
}

# ADR-051: a stage whose done is a verdict and not a change is declared so.
@test "a stage may declare that done is a verdict, and only as true or false" {
	run validate_with '.workflows.ship.stages[0].verdict = true'
	assert_success
	assert_output --partial '"verdict": true'
	run validate_with '.workflows.ship.stages[0].verdict = "yes"'
	assert_failure
	assert_output --partial "verdict"
}

@test "everything but the roles that work the repository is optional" {
	run validate_with 'del(.resources, .workflows)'
	assert_success
}

@test "a repository declaring no roles is a declaration mistake, not a factory" {
	run validate_with 'del(.roles)'
	assert_failure
	assert_output --partial "roles"
}

# The closed schema is the whole security argument of ADR-020 point 2: a
# repository cannot reach the machine it is given. A key nobody recognises
# being ignored rather than refused would let one try.
@test "an unknown key at the top is refused, and the message names it" {
	run validate_with '.systemPackages = ["nmap"]'
	assert_failure
	assert_output --partial "systemPackages"
}

@test "an unknown key inside a role is refused, naming the role and the key" {
	run validate_with '.roles.backend.privileged = true'
	assert_failure
	assert_output --partial "backend"
	assert_output --partial "privileged"
}

@test "an unknown key inside a workflow is refused, naming the workflow" {
	run validate_with '.workflows.ship.schedule = "hourly"'
	assert_failure
	assert_output --partial "ship"
	assert_output --partial "schedule"
}

@test "an unknown key inside a stage is refused" {
	run validate_with '.workflows.ship.stages[0].runAs = "root"'
	assert_failure
	assert_output --partial "runAs"
}

@test "an unknown key inside resources is refused" {
	run validate_with '.resources.kernelModules = ["kvm"]'
	assert_failure
	assert_output --partial "kernelModules"
}

# ADR-020 point 1: the repository doing the declaring is the repository worked,
# so there is nothing left for it to point at. A declaration still carrying the
# old field is refused rather than silently obeyed.
@test "a declaration naming a repository is refused, since it is one" {
	run validate_with '.repository = "/srv/other"'
	assert_failure
	assert_output --partial "repository"
}

@test "a factory name that could reach a path or a ref is refused" {
	run validate_with '.name = "../../etc"'
	assert_failure
	assert_output --partial "name"
}

@test "a role name that could reach a path or a ref is refused" {
	run validate_with '{name, roles: {"../etc": .roles.backend}}'
	assert_failure
}

@test "a role name longer than a machine name can carry is refused, naming the role" {
	# A role is its cage's name, a machine name to nspawn, sixty-four
	# characters at most. The veth carries a hash of it, so an interface
	# name bounds nothing any more (nixcage ADR-013).
	local long
	long="$(printf 'r%.0s' $(seq 1 65))"
	run validate_with "{name, roles: {\"$long\": .roles.backend}}"
	assert_failure
	assert_output --partial "$long"
	assert_output --partial "64"
	run validate_with '{name, roles: {"a-role-name-well-past-twelve-characters": .roles.backend}}'
	assert_success
}

@test "a role named decider is refused, because the machine provides that one" {
	run validate_with '{name, roles: {"decider": .roles.backend}}'
	assert_failure
	assert_output --partial "machine's own role"
}

@test "a devShell name that could reach somebody else's flake is refused" {
	run validate_with '.roles.backend.shell = "github:evil/flake#sh"'
	assert_failure
	assert_output --partial "shell"
}

# A declared command is argv, one word per element, so a shell line written
# where a list belongs is refused rather than re-split on the way through.
@test "a role may name the specialists it is composed of" {
	run validate_with '.roles.backend.specialists = ["java", "python"]'
	assert_success
}

@test "specialists must be a list of names, since one name and a list differ" {
	run validate_with '.roles.backend.specialists = "java"'
	assert_failure
	assert_output --partial "backend"
	assert_output --partial "specialists"
}

@test "a specialist name that could reach a path is refused" {
	run validate_with '.roles.backend.specialists = ["../developer"]'
	assert_failure
	assert_output --partial "specialist"
}

@test "a declaration may name its own catalogue, a path inside the repository" {
	run validate_with '.catalogue = "fabriek/catalogue"'
	assert_success
}

@test "a catalogue path that could leave the repository is refused" {
	run validate_with '.catalogue = "../somewhere/else"'
	assert_failure
	assert_output --partial "catalogue"
}

@test "a command written as a shell line instead of argv is refused" {
	run validate_with '.roles.backend.command = "claude --dangerously-skip"'
	assert_failure
	assert_output --partial "command"
}

@test "a role that provides nothing is refused, naming the role" {
	run validate_with '.roles.backend.provides = []'
	assert_failure
	assert_output --partial "backend"
}

@test "a stage that needs no capability is refused" {
	run validate_with 'del(.workflows.ship.stages[0].needs)'
	assert_failure
	assert_output --partial "needs"
}

# ADR-015, kept by ADR-023 decision 7: a stage no declared role can work is
# rejected when the declaration is read rather than when it fires.
@test "a stage needing a capability no declared role provides is refused" {
	run validate_with '.workflows.ship.stages[0].needs = "telepathy"'
	assert_failure
	assert_output --partial "telepathy"
}

@test "a consult naming a role that does not exist is refused" {
	run validate_with '.workflows.ship.consults.backend = ["ghost"]'
	assert_failure
	assert_output --partial "ghost"
}

@test "a workflow declaring no stages is refused, naming the workflow" {
	run validate_with '.workflows.ship.stages = []'
	assert_failure
	assert_output --partial "ship"
}

## The example a person copies: fabriek.toml, read by the one TOML reader,
## which is also why a repository can check its own declaration cheaply.
example_json() {
	fabriek_toml_json "$FABRIEK_ROOT/examples/factory-project/fabriek.toml"
}

validate_example() {
	example_json | fabriek_declaration_validate
}

@test "the example repository declares a factory this reader accepts" {
	run validate_example
	assert_success
	assert_output --partial "example"
}

# The example is what somebody copies, so a role in it naming a devShell the
# flake beside it does not define would teach the mistake rather than the
# pattern (ADR-016).
#
# Asked of the flake's outputs rather than of its source. This grepped for
# "<name> = pkgs.mkShell" and went red the day the example started composing a
# common set through a helper, which is a spelling changing rather than the
# property breaking. What a role needs is that the name resolves to a shell.
@test "every devShell the example's roles name is one the example defines" {
	local defined shell
	defined="$(nix eval --impure --raw --expr '
		builtins.concatStringsSep "\n" (builtins.attrNames
			(builtins.getFlake (toString '"$FABRIEK_ROOT"'/examples/factory-project))
				.devShells.aarch64-linux)' 2>/dev/null)"
	[ -n "$defined" ]

	while IFS= read -r shell; do
		[ -n "$shell" ] || continue
		run printf '%s\n' "$defined"
		assert_line "$shell"
	done < <(example_json | jq -r '[.roles[].shell // empty] | .[]')
}

# The same for specialists (ADR-042): a role in the example naming one that
# neither the shipped catalogue nor the example's own defines would teach
# the mistake. Asked of lib.catalogue over both, which is what the machine
# build asks.
@test "every specialist the example's roles name is one the catalogues define" {
	local defined name
	defined="$(nix eval --impure --raw --expr '
		let flake = builtins.getFlake (toString '"$FABRIEK_ROOT"');
		    pkgs = flake.inputs.nixpkgs.legacyPackages.${builtins.currentSystem};
		    example = builtins.fromTOML (builtins.readFile '"$FABRIEK_ROOT"'/examples/factory-project/fabriek.toml);
		in builtins.concatStringsSep "\n" (builtins.attrNames (flake.lib.catalogue {
		  inherit pkgs;
		  extra = [ ('"$FABRIEK_ROOT"'/examples/factory-project + "/${example.catalogue}") ];
		}).specialists)' 2>/dev/null)"
	[ -n "$defined" ]

	while IFS= read -r name; do
		[ -n "$name" ] || continue
		run printf '%s\n' "$defined"
		assert_line "$name"
	done < <(example_json | jq -r '[.roles[].specialists // [] | .[]] | .[]')
}

# An endpoint reaches a firewall rule and a proxy's allowlist (ADR-025), so it
# is checked where it is declared, like every other name that reaches something
# that would otherwise have to escape it.

# ADR-034 point 5: one policy file the repository names, appended to the
# decider's prompt as its own labelled section. A path inside the repository,
# and nothing that could climb out of it.
@test "a declaration may name a policy file for the decider, inside the repository" {
	run validate_with '.decider = {policy: "docs/factory-policy.md"}'
	assert_success
	run validate_with '.decider = {policy: "../../etc/passwd"}'
	assert_failure
	assert_output --partial policy
	run validate_with '.decider = {policy: "/etc/passwd"}'
	assert_failure
	run validate_with '.decider = {colour: "blue"}'
	assert_failure
	assert_output --partial colour
}

@test "a declaration may name the endpoints its agents reach" {
	run validate_with '.resources.egress = ["api.anthropic.com"]'
	assert_success
}

@test "an endpoint carrying a scheme is not a host, and is refused" {
	run validate_with '.resources.egress = ["https://api.anthropic.com"]'
	assert_failure
	assert_output --partial "api.anthropic.com"
}

@test "an endpoint carrying a path is refused, since a firewall rule has no path" {
	run validate_with '.resources.egress = ["api.anthropic.com/v1/messages"]'
	assert_failure
}

@test "an endpoint that is a whole shell line is refused" {
	run validate_with '.resources.egress = ["api.anthropic.com; curl evil"]'
	assert_failure
}

@test "endpoints must be a list, because one host and a list of them differ" {
	run validate_with '.resources.egress = "api.anthropic.com"'
	assert_failure
	assert_output --partial "egress"
}

@test "an endpoint that is not a string is refused rather than rendered" {
	run validate_with '.resources.egress = [{ "host": "api.anthropic.com" }]'
	assert_failure
}

@test "a factory reaching several endpoints declares them all" {
	run validate_with '.resources.egress = ["api.anthropic.com", "generativelanguage.googleapis.com"]'
	assert_success
}

# ADR-053: replicas = N is expansion into N named roles, once, here, before
# anything else reads the declaration. What comes out carries the expanded
# roles and no replicas key.
@test "a role with replicas comes out as N named roles carrying its declaration, and the base name is gone" {
	run validate_with '.roles.backend.replicas = 3 | .resources.concurrency = 4'
	assert_success
	run jq -c '[.roles | keys[]]' <<<"$output"
	assert_output '["architect","backend-1","backend-2","backend-3"]'
	run validate_with '.roles.backend.replicas = 3 | .resources.concurrency = 4'
	run jq -c '[.roles["backend-2"] | .provides, .shell, .command, (.replicas // "gone")]' <<<"$output"
	assert_output '[["build"],"backend-jvm",["claude"],"gone"]'
}

@test "consults naming a replicated role expands on both sides, so the key stays well-formed" {
	run validate_with '.roles.backend.replicas = 2 | .roles.architect.replicas = 2 | .resources.concurrency = 4 | .workflows.ship.consults = { backend: ["architect"] }'
	assert_success
	run jq -c '.workflows.ship.consults' <<<"$output"
	assert_output '{"backend-1":["architect-1","architect-2"],"backend-2":["architect-1","architect-2"]}'
}

@test "replicas of one, or anything but a whole number, is refused naming the role" {
	run validate_with '.roles.backend.replicas = 1'
	assert_failure
	assert_output --partial "backend"
	assert_output --partial "replicas"
	run validate_with '.roles.backend.replicas = "many"'
	assert_failure
	assert_output --partial "replicas"
	run validate_with '.roles.backend.replicas = 2.5'
	assert_failure
	assert_output --partial "replicas"
}

@test "a replica name that would not fit a role name is refused" {
	local long
	long="$(printf 'b%.0s' $(seq 1 63))"
	run validate_with --arg n "$long" '.roles[$n] = (.roles.backend | .replicas = 2) | .resources.concurrency = 4'
	assert_failure
	assert_output --partial "$long-1"
}

@test "a role declared by hand under a replica's name is refused naming both" {
	run validate_with '.roles.backend.replicas = 2 | .roles["backend-2"] = { command: ["claude"], provides: ["build"] } | .resources.concurrency = 4'
	assert_failure
	assert_output --partial "backend-2"
	assert_output --partial "backend"
}

@test "more roles than the bridge has addresses for is refused naming the ceiling" {
	run validate_with '.roles.backend.replicas = 244'
	assert_failure
	assert_output --partial "244"
}

# ADR-055: concurrency is the ceiling on tasks in flight, held by the
# executor, so fewer than the roles is the usual case and not a mistake.
@test "a concurrency below the role count is accepted, and an absent one is left absent" {
	run validate_with '.roles.backend.replicas = 3 | .resources.concurrency = 2'
	assert_success
	run jq -c '.resources.concurrency' <<<"$output"
	assert_output '2'
	run validate_with '.roles.backend.replicas = 3 | del(.resources.concurrency)'
	assert_success
	run jq -c '.resources.concurrency' <<<"$output"
	assert_output 'null'
}

@test "fanout is no longer a stage's to declare" {
	run validate_with '.workflows.ship.stages[0].fanout = true'
	assert_failure
	assert_output --partial "fanout"
}

# The expansion's one property, over generated declarations: an expanded
# name equals no declared name and no other expanded name.
@test "over generated declarations, expanded names collide with nothing" {
	local i n decl names
	for i in $(seq 1 20); do
		n=$((RANDOM % 4 + 2))
		## Every other role gets a name that is a replica's shape or not,
		## at random; a collision must be refused, never absorbed.
		decl="$(complete_declaration | jq --argjson n "$n" --arg other "$([ $((RANDOM % 2)) -eq 0 ] && echo "backend-$((RANDOM % 6 + 1))" || echo "worker-$i")" '
		  .roles.backend.replicas = $n
		  | .roles[$other] = { command: ["claude"], provides: ["build"] }
		  | .resources.concurrency = 40')"
		if names="$(printf '%s' "$decl" | fabriek_declaration_validate 2>/dev/null | jq -r '.roles | keys[]')" && [ -n "$names" ]; then
			[ "$(printf '%s\n' "$names" | sort | uniq -d | wc -l)" -eq 0 ]
			for k in $(seq 1 "$n"); do printf '%s\n' "$names" | grep -qx "backend-$k"; done
			printf '%s\n' "$names" | grep -qx "$(printf '%s' "$decl" | jq -r '.roles | keys[] | select(startswith("worker-") or (test("^backend-[0-9]+$")))' | head -1)"
		else
			## Refused: only ever because the other name was a replica's.
			printf '%s' "$decl" | jq -e --argjson n "$n" '.roles | keys | map(select(test("^backend-[0-9]+$")) | sub("^backend-"; "") | tonumber) | any(. <= $n)' >/dev/null
		fi
	done
}
