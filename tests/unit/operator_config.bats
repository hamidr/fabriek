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
	XDG_CONFIG_HOME="$TEST_TEMP_DIR/xdg" run cageworks_operator_config_path
	assert_success
	assert_output "$TEST_TEMP_DIR/xdg/cageworks/config.toml"
}
