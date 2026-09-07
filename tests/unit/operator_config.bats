#!/usr/bin/env bats
# The one file the operator owns: what a factory may cost on this machine, and
# which factories live here (ADR-020 point 4).

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/names.sh
	source "$CAGEWORKS_ROOT/modules/names.sh"
	# shellcheck source=../../modules/schema.sh
	source "$CAGEWORKS_ROOT/modules/schema.sh"
	# shellcheck source=../../modules/sizes.sh
	source "$CAGEWORKS_ROOT/modules/sizes.sh"
	# shellcheck source=../../modules/resources.sh
	source "$CAGEWORKS_ROOT/modules/resources.sh"
	# shellcheck source=../../modules/operator-config.sh
	source "$CAGEWORKS_ROOT/modules/operator-config.sh"
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
roleQuota = "50G"
concurrency = 4

[factories.acme]
path = "/home/me/Src/acme"

[factories.widgets]
path = "/home/me/Src/widgets"
TOML
}

@test "the ceilings are what the operator wrote" {
	run cageworks_operator_caps "$CONFIG"
	assert_success
	assert_output --partial '"memory": "16G"'
	assert_output --partial '"cores": 8'
}

@test "a registered factory is found by the path it was registered at" {
	run cageworks_operator_factory_path "$CONFIG" acme
	assert_success
	assert_output "/home/me/Src/acme"
}

@test "the factories on this machine are listed in a stable order" {
	run cageworks_operator_factories "$CONFIG"
	assert_success
	assert_line --index 0 "acme"
	assert_line --index 1 "widgets"
}

@test "a factory nobody registered here is refused by name" {
	run cageworks_operator_factory_path "$CONFIG" ghost
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
	run cageworks_operator_caps "$CONFIG"
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
	run cageworks_operator_caps "$CONFIG"
	assert_failure
	assert_output --partial "supervisor"
}

@test "an unknown key under a factory is refused" {
	cat >"$CONFIG" <<'TOML'
[factories.acme]
path = "/home/me/Src/acme"
branch = "main"
TOML
	run cageworks_operator_factories "$CONFIG"
	assert_failure
	assert_output --partial "branch"
}

@test "a factory registered without a path is refused, naming the factory" {
	cat >"$CONFIG" <<'TOML'
[factories.acme]
TOML
	run cageworks_operator_factories "$CONFIG"
	assert_failure
	assert_output --partial "acme"
}

@test "a registered name that could reach a path or a ref is refused" {
	cat >"$CONFIG" <<'TOML'
[factories."../../etc"]
path = "/home/me/Src/acme"
TOML
	run cageworks_operator_factories "$CONFIG"
	assert_failure
}

# Failing safe. A config that is not there would otherwise mean no ceilings,
# and no ceilings means a repository gets whatever it asked for.
@test "a config that is not there is refused, and the message is the path" {
	run cageworks_operator_caps "$TEST_TEMP_DIR/absent.toml"
	assert_failure
	assert_output --partial "absent.toml"
}

@test "a config that is not TOML is refused rather than read as empty" {
	printf 'this is not = = toml\n' >"$CONFIG"
	run cageworks_operator_caps "$CONFIG"
	assert_failure
}

# The file's content is never evaluated as Nix, only parsed as TOML, which is
# what lets nix be the parser without the file being able to reach the reader.
@test "a config that looks like a nix expression is still only TOML" {
	printf 'x = "${builtins.currentTime}"\n' >"$CONFIG"
	run cageworks_operator_caps "$CONFIG"
	assert_failure
	assert_output --partial "x"
}

@test "the config lives where the operator's own config lives" {
	unset CAGEWORKS_CONFIG
	XDG_CONFIG_HOME="$TEST_TEMP_DIR/xdg" run cageworks_operator_config_path
	assert_success
	assert_output "$TEST_TEMP_DIR/xdg/cageworks/config.toml"
}

@test "an operator with more than one config says which, and it wins" {
	CAGEWORKS_CONFIG="$TEST_TEMP_DIR/other.toml" run cageworks_operator_config_path
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
	run cageworks_operator_caps "$CONFIG"
	assert_success
	assert_output --partial 'api.anthropic.com'
}

@test "an operator who names no endpoints has a ceiling, not an absence" {
	run cageworks_operator_caps "$CONFIG"
	assert_success
	refute_output --partial 'egress'
}

# ADR-025 point 2: the credential is the operator's, and it says which header
# carries it for which endpoint. The path is here and never reaches the guest:
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
	run cageworks_operator_credentials "$CONFIG"
	assert_success
	assert_output --partial "x-api-key"
	assert_output --partial "api.anthropic.com"
}

@test "an operator holding no credentials holds none, which is not an error" {
	run cageworks_operator_credentials "$CONFIG"
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
	run cageworks_operator_credentials "$CONFIG"
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
	run cageworks_operator_credentials "$CONFIG"
	assert_failure
}

@test "a credential with no file to read it from is refused" {
	cat >"$CONFIG" <<TOML
[credentials."api.anthropic.com"]
header = "x-api-key"

[factories.acme]
path = "/home/me/Src/acme"
TOML
	run cageworks_operator_credentials "$CONFIG"
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
	run cageworks_operator_credentials "$CONFIG"
	assert_failure
	assert_output --partial "command"
}
