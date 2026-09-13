#!/usr/bin/env bats
# What a role can be (ADR-042): lib.catalogue, evaluated for real over the
# shipped catalogue and over a second one a scenario writes. Composition is
# evaluated; the derivation it yields is built only where what is inside it
# is the claim, on fixture tools that cost nothing to realise.

load ../test_helper/common

setup() {
	setup_temp_dir
	EXTRA="$TEST_TEMP_DIR/catalogue"
	mkdir -p "$EXTRA/specialists" "$EXTRA/skills"
}

teardown() {
	teardown_temp_dir
}

## A specialist in the scenario's own catalogue. Body is the attribute set's
## inside; the prompt is one line naming the specialist so order shows.
specialist() {
	mkdir -p "$EXTRA/specialists/$1"
	printf 'I am %s.\n' "$1" >"$EXTRA/specialists/$1/PROMPT.md"
	printf '{ pkgs, specialists, skills, ... }:\n{ prompt = ./PROMPT.md; %s }\n' "$2" >"$EXTRA/specialists/$1/default.nix"
}

## A skill in the scenario's own catalogue, with the frontmatter given.
skill() {
	mkdir -p "$EXTRA/skills/$1"
	printf -- '---\n%s\n---\n\n# %s\n' "$2" "$1" >"$EXTRA/skills/$1/SKILL.md"
	printf '{ pkgs, ... }:\n{ src = ./.; %s }\n' "$3" >"$EXTRA/skills/$1/default.nix"
}

## One attribute of lib.catalogue over the shipped catalogue and the
## scenario's, as JSON. The channel warning is noise on every impure
## evaluation and is dropped.
catalogue_eval() {
	nix eval --json --impure --expr "
	  let flake = builtins.getFlake \"path:$FABRIEK_ROOT\";
	      pkgs = flake.inputs.nixpkgs.legacyPackages.\${builtins.currentSystem};
	      cat = flake.lib.catalogue { inherit pkgs; extra = [ $EXTRA ]; };
	  in $1" \
		2> >(grep -v -e 'Nix search path entry' >&2)
}

## Build what a role gets and print its store path.
catalogue_build() {
	nix build --no-link --print-out-paths --impure --expr "
	  let flake = builtins.getFlake \"path:$FABRIEK_ROOT\";
	      pkgs = flake.inputs.nixpkgs.legacyPackages.\${builtins.currentSystem};
	      cat = flake.lib.catalogue { inherit pkgs; extra = [ $EXTRA ]; };
	  in $1" \
		2> >(grep -v -e 'Nix search path entry' >&2)
}

@test "the shipped catalogue offers its specialists by directory name" {
	run catalogue_eval 'builtins.attrNames cat.specialists'
	assert_success
	assert_output '["architect","developer","django","flask","frontend","java","python","reviewer","springboot"]'
}

@test "a role naming java and python is composed with developer once, parents first" {
	run catalogue_eval '(cat.compose { role = "backend"; specialists = [ "java" "python" ]; }).order'
	assert_success
	assert_output '["developer","java","python"]'
}

@test "a composed role carries every tool of every specialist it flattens" {
	run catalogue_eval 'map (t: t.pname or t.name) (cat.compose { role = "backend"; specialists = [ "java" "python" ]; }).tools'
	assert_success
	assert_output --partial '"ripgrep"'
	assert_output --partial '"maven"'
	assert_output --partial '"ruff"'
}

# Asked through .name, which nothing in the composition depends on: the
# refusal has to come on any touch of the derivation, not only on the
# attributes that happen to read the list.
@test "a role naming a specialist no catalogue has is refused naming the role and what is offered" {
	run catalogue_eval '(cat.compose { role = "backend"; specialists = [ "rust" ]; }).name'
	assert_failure
	assert_output --partial "role backend names specialist rust"
	assert_output --partial "offers: architect, developer"
}

@test "a repository's own catalogue adds a specialist beside the shipped ones" {
	specialist local 'extends = [ specialists.developer ];'
	run catalogue_eval '(cat.compose { role = "backend"; specialists = [ "local" ]; }).order'
	assert_success
	assert_output '["developer","local"]'
}

@test "a specialist declared in two catalogues is refused, never shadowed" {
	specialist java ''
	run catalogue_eval 'builtins.attrNames cat.specialists'
	assert_failure
	assert_output --partial "specialist java is declared twice"
}

@test "a cycle in extends is refused naming the cycle" {
	specialist a 'extends = [ specialists.b ];'
	specialist b 'extends = [ specialists.a ];'
	run catalogue_eval '(cat.compose { role = "backend"; specialists = [ "a" ]; }).order'
	assert_failure
	assert_output --partial "a -> b -> a"
}

@test "a key outside the schema is refused by that key's name" {
	specialist odd 'colour = "blue";'
	run catalogue_eval '(cat.compose { role = "backend"; specialists = [ "odd" ]; }).order'
	assert_failure
	assert_output --partial "specialist odd"
	assert_output --partial "colour"
}

@test "what a role gets carries the prompts in order under headings and each skill by name" {
	skill one 'name: one
description: the first' ''
	specialist x 'skills = [ skills.one ]; tools = [ (pkgs.writeShellScriptBin "tx" "") ];'
	specialist y 'extends = [ specialists.x ];'
	run catalogue_build 'cat.compose { role = "backend"; specialists = [ "y" ]; }'
	assert_success
	out="$output"
	run cat "$out/share/fabriek/specialist/APPEND_SYSTEM.md"
	assert_line --index 0 "## x"
	assert_line --index 1 "I am x."
	assert_line --index 2 "## y"
	assert_line --index 3 "I am y."
	[ -f "$out/share/fabriek/specialist/skills/one/SKILL.md" ]
	[ -x "$out/bin/tx" ]
}

@test "two specialists carrying one bin file from different packages fail the build naming both" {
	specialist x 'tools = [ (pkgs.writeShellScriptBin "same" "a") ];'
	specialist y 'tools = [ (pkgs.writeShellScriptBin "same" "b") ];'
	run catalogue_build 'cat.compose { role = "backend"; specialists = [ "x" "y" ]; }'
	assert_failure
	assert_output --partial "bin/same"
	assert_output --partial "x"
	assert_output --partial "y"
}

@test "a skill whose SKILL.md has no description fails the build naming the skill" {
	skill nodesc 'name: nodesc' ''
	specialist x 'skills = [ skills.nodesc ];'
	run catalogue_build 'cat.compose { role = "backend"; specialists = [ "x" ]; }'
	assert_failure
	assert_output --partial "skill nodesc"
	assert_output --partial "description"
}
