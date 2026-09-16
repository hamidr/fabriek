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
## The operator's TOML-declared specialists and skills (ADR-061 point 3),
## as the credential's JSON, handed to the catalogue as `declared`.
DECLARED='{ specialists = { }; skills = { }; }'

catalogue_eval() {
	nix eval --json --impure --expr "
	  let flake = builtins.getFlake \"path:$FABRIEK_ROOT\";
	      pkgs = flake.inputs.nixpkgs.legacyPackages.\${builtins.currentSystem};
	      cat = flake.lib.catalogue { inherit pkgs; extra = [ $EXTRA ]; declared = $DECLARED; };
	  in $1" \
		2> >(grep -v -e 'Nix search path entry' >&2)
}

## Build what a role gets and print its store path.
catalogue_build() {
	nix build --no-link --print-out-paths --impure --expr "
	  let flake = builtins.getFlake \"path:$FABRIEK_ROOT\";
	      pkgs = flake.inputs.nixpkgs.legacyPackages.\${builtins.currentSystem};
	      cat = flake.lib.catalogue { inherit pkgs; extra = [ $EXTRA ]; declared = $DECLARED; };
	  in $1" \
		2> >(grep -v -e 'Nix search path entry' >&2)
}

@test "the shipped catalogue offers its specialists by directory name" {
	run catalogue_eval 'builtins.attrNames cat.specialists'
	assert_success
	assert_output '["architect","committer","developer","django","flask","frontend","java","manager","python","react","reviewer","scala","springboot"]'
}

@test "the shipped java and python specialists declare their language servers, composed into one lsp.json" {
	run catalogue_eval 'map (s: s.id) (builtins.fromJSON (builtins.unsafeDiscardStringContext (cat.compose { role = "backend"; specialists = [ "springboot" "django" ]; }).lspJson)).servers'
	assert_success
	assert_output '["jdtls","basedpyright"]'
}

@test "a role naming java and python is composed with committer and developer once, parents first" {
	run catalogue_eval '(cat.compose { role = "backend"; specialists = [ "java" "python" ]; }).order'
	assert_success
	assert_output '["committer","developer","java","python"]'
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
	assert_output --partial "offers: architect, committer, developer"
}

@test "a repository's own catalogue adds a specialist beside the shipped ones" {
	specialist local 'extends = [ specialists.developer ];'
	run catalogue_eval '(cat.compose { role = "backend"; specialists = [ "local" ]; }).order'
	assert_success
	assert_output '["committer","developer","local"]'
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

# ADR-043: a server is declared by a specialist and reaches pi-lsp as one
# entry of the role's lsp.json, id once however many paths reach it.
@test "a role's lsp.json is the union of its specialists' servers by id, a diamond declaring one once" {
	specialist base 'lsp = [ { id = "nil"; include = [ "**/*.nix" ]; rootMarkers = [ "flake.nix" ]; bin = "/bin/nil"; languageIdByExtension = { ".nix" = "nix"; }; } ];'
	specialist x 'extends = [ specialists.base ]; lsp = [ { id = "tsserver"; include = [ "**/*.ts" ]; rootMarkers = [ "package.json" ]; bin = "/bin/tsserver"; args = [ "--stdio" ]; languageIdByExtension = { ".ts" = "typescript"; }; } ];'
	specialist y 'extends = [ specialists.base ];'
	run catalogue_build 'cat.compose { role = "backend"; specialists = [ "x" "y" ]; }'
	assert_success
	run jq -c '[.version, (.servers | map(.id)), .servers[0].enabled, .servers[0].cwd, .servers[1].args]' "$output/share/fabriek/specialist/lsp.json"
	assert_output '[1,["nil","tsserver"],true,"{root}",["--stdio"]]'
}

@test "a role whose specialists declare no server gets an lsp.json with none" {
	specialist x ''
	run catalogue_build 'cat.compose { role = "backend"; specialists = [ "x" ]; }'
	assert_success
	run jq -c '.servers' "$output/share/fabriek/specialist/lsp.json"
	assert_output '[]'
}

@test "one server id from two unrelated specialists is refused naming both" {
	specialist x 'lsp = [ { id = "pyright"; include = [ "**/*.py" ]; rootMarkers = [ "pyproject.toml" ]; bin = "/a/pyright"; languageIdByExtension = { ".py" = "python"; }; } ];'
	specialist y 'lsp = [ { id = "pyright"; include = [ "**/*.py" ]; rootMarkers = [ "setup.py" ]; bin = "/b/pyright"; languageIdByExtension = { ".py" = "python"; }; } ];'
	run catalogue_eval '(cat.compose { role = "backend"; specialists = [ "x" "y" ]; }).name'
	assert_failure
	assert_output --partial "server pyright"
	assert_output --partial "x"
	assert_output --partial "y"
}

# ADR-044: what a test is and how tests run, declared per specialist and
# unioned for the role, so the loop's guard can classify without reading.
@test "a role's tests.json is the union of its specialists' test files, source files and commands" {
	specialist x 'tests = { files = [ "**/*_test.py" ]; source = [ "src/**" ]; command = [ "pytest" ]; };'
	specialist y 'extends = [ specialists.x ]; tests = { files = [ "tests/**" ]; source = [ "src/**" ]; command = [ "python -m pytest" ]; };'
	run catalogue_build 'cat.compose { role = "backend"; specialists = [ "y" ]; }'
	assert_success
	run jq -c '[.files, .source, .command]' "$output/share/fabriek/specialist/tests.json"
	assert_output '[["**/*_test.py","tests/**"],["src/**"],["pytest","python -m pytest"]]'
}

@test "a role whose specialists declare no tests gets a tests.json with empty lists, so no guard" {
	specialist x ''
	run catalogue_build 'cat.compose { role = "backend"; specialists = [ "x" ]; }'
	assert_success
	run jq -c '[.files, .source, .command]' "$output/share/fabriek/specialist/tests.json"
	assert_output '[[],[],[]]'
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

# What a role is composed of, at evaluation and without a build, so that a
# check on the operator's host and a listing can say it in seconds (task 1).
@test "a composed role says its order, tools, skills with descriptions, servers and prompt without a build" {
	run catalogue_eval 'let c = cat.compose { role = "backend"; specialists = [ "springboot" "django" ]; }; in
	  { inherit (c) order; tools = map (t: t.pname or t.name) c.tools;
	    skills = map (s: { inherit (s) name; hasDescription = s.description != ""; }) c.skillsDescribed;
	    servers = c.servers; hasPrompt = builtins.stringLength c.promptText > 100; }'
	assert_success
	run jq -c '[.order, (.tools | index("maven") != null), (.skills | map(.name)), (.skills | all(.hasDescription)), .servers, .hasPrompt]' <<<"$output"
	assert_output '[["committer","developer","java","springboot","python","django"],true,["tool-missing","tdd","ddd","solid-fp","debugging","proof-before-done","review-findings","jvm-profile","spring-boot-run","django-migrate"],true,["jdtls","basedpyright"],true]'
}

@test "the catalogue lists every skill with the description pi shows for it" {
	run catalogue_eval 'builtins.attrNames cat.skillsDescribed'
	assert_success
	assert_output --partial '"tdd"'
	run catalogue_eval 'cat.skillsDescribed.tdd.description'
	assert_success
	assert_output --partial "failing test first"
}

# ADR-061 point 3: a specialist or a skill declared in the operator's file,
# tools by nixpkgs attribute, a prompt or a SKILL.md by path or as text,
# composes like one from a directory and is refused like one.
@test "a specialist declared in TOML composes with a shipped parent, its tools on PATH and its prompt under its heading" {
	printf -- '---\nname: profile\ndescription: profiles it\n---\n\n# Profile\n' >"$TEST_TEMP_DIR/SKILL.md"
	DECLARED="builtins.fromJSON ''{
	  \"specialists\": { \"strict\": { \"extends\": [\"reviewer\"], \"tools\": [\"hello\"], \"skills\": [\"profile\"], \"prompt\": \"Be strict.\" } },
	  \"skills\": { \"profile\": { \"tools\": [\"cowsay\"], \"skill\": \"$TEST_TEMP_DIR/SKILL.md\" } } }''"
	run catalogue_eval '(cat.compose { role = "reviewer"; specialists = [ "strict" ]; }).order'
	assert_success
	assert_output '["committer","reviewer","strict"]'
	run catalogue_build 'cat.compose { role = "reviewer"; specialists = [ "strict" ]; }'
	assert_success
	out="$output"
	[ -x "$out/bin/hello" ]
	[ -x "$out/bin/cowsay" ]
	run grep -A2 '^## strict$' "$out/share/fabriek/specialist/APPEND_SYSTEM.md"
	assert_line --index 1 "Be strict."
	[ -f "$out/share/fabriek/specialist/skills/profile/SKILL.md" ]
	run catalogue_eval 'cat.skillsDescribed.profile.description'
	assert_output '"profiles it"'
}

@test "a TOML specialist naming a tool nixpkgs lacks, a parent or a skill nothing has, is refused by name" {
	DECLARED="builtins.fromJSON ''{ \"specialists\": { \"x\": { \"tools\": [\"no-such-package-xyz\"], \"prompt\": \"p\" } }, \"skills\": {} }''"
	run catalogue_eval '(cat.compose { role = "r"; specialists = [ "x" ]; }).order'
	assert_failure
	assert_output --partial "specialist x: tool no-such-package-xyz is not a package of nixpkgs"
	DECLARED="builtins.fromJSON ''{ \"specialists\": { \"x\": { \"extends\": [\"nobody\"], \"prompt\": \"p\" } }, \"skills\": {} }''"
	run catalogue_eval '(cat.compose { role = "r"; specialists = [ "x" ]; }).order'
	assert_failure
	assert_output --partial "specialist x extends nobody, which no catalogue declares"
	DECLARED="builtins.fromJSON ''{ \"specialists\": { \"x\": { \"skills\": [\"nothing\"], \"prompt\": \"p\" } }, \"skills\": {} }''"
	run catalogue_eval '(cat.compose { role = "r"; specialists = [ "x" ]; }).order'
	assert_failure
	assert_output --partial "specialist x names skill nothing, which no catalogue declares"
}

@test "a TOML specialist named like a shipped or a directory one is refused, never shadowed" {
	DECLARED="builtins.fromJSON ''{ \"specialists\": { \"developer\": { \"prompt\": \"p\" } }, \"skills\": {} }''"
	run catalogue_eval 'builtins.attrNames cat.specialists'
	assert_failure
	assert_output --partial "specialist developer is declared twice"
}

# ADR-062: a catalogue fetched from a git tree at a rev composes like a
# directory, since on the machine it is one: the store path the host
# fetched it to.
@test "a catalogue from a git tree at a rev composes a specialist onto a role's PATH" {
	local cat="$TEST_TEMP_DIR/gitcat"
	mkdir -p "$cat/specialists/tx"
	git init -q -b main "$cat"
	git -C "$cat" config user.name c
	git -C "$cat" config user.email c@invalid
	printf 'I am tx.\n' >"$cat/specialists/tx/PROMPT.md"
	printf '{ pkgs, ... }: { prompt = ./PROMPT.md; tools = [ (pkgs.writeShellScriptBin "tx" "") ]; }\n' >"$cat/specialists/tx/default.nix"
	git -C "$cat" add -A
	git -C "$cat" -c commit.gpgsign=false commit -qm tx
	local rev fetched
	rev="$(git -C "$cat" rev-parse HEAD)"
	fetched="$(nix flake prefetch --json "git+file://$cat?rev=$rev" | jq -r .storePath)"
	EXTRA="$fetched"
	run catalogue_build 'cat.compose { role = "backend"; specialists = [ "tx" ]; }'
	assert_success
	[ -x "$output/bin/tx" ]
	run grep -c 'I am tx.' "$output/share/fabriek/specialist/APPEND_SYSTEM.md"
	assert_output 1
}
