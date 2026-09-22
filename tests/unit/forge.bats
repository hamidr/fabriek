#!/usr/bin/env bats
# The forge as prepare speaks to it (ADR-036, ADR-068). One Forgejo serves
# every factory now, and its CLI opens the sqlite database beside the
# running server, so every CLI call takes a lock the whole host shares
# while two factories prepare under locks of their own (ADR-068 point 5).
# The API takes none: the server serialises what reaches it.

load ../test_helper/common

setup() {
	setup_temp_dir
	STUB_DIR="$TEST_TEMP_DIR/bin"
	CALLS="$TEST_TEMP_DIR/calls"
	mkdir -p "$STUB_DIR"
	PATH="$STUB_DIR:$PATH"
	export PATH CALLS
	export FABRIEK_FORGE_STATE="$TEST_TEMP_DIR/forge-state"
	# flock as util-linux's: its own words, then the command it runs.
	cat >"$STUB_DIR/flock" <<EOF
#!/usr/bin/env bash
printf 'flock %s\n' "\$1" >>"$CALLS"
shift
"\$@"
EOF
	cat >"$STUB_DIR/forgejo" <<EOF
#!/usr/bin/env bash
printf 'forgejo %s\n' "\$*" >>"$CALLS"
EOF
	cat >"$STUB_DIR/curl" <<EOF
#!/usr/bin/env bash
printf 'curl\n' >>"$CALLS"
echo '{}'
EOF
	chmod +x "$STUB_DIR/flock" "$STUB_DIR/forgejo" "$STUB_DIR/curl"
	# shellcheck source=../../modules/names.sh
	source "$FABRIEK_ROOT/modules/names.sh"
	# shellcheck source=../../modules/forge.sh
	source "$FABRIEK_ROOT/modules/forge.sh"
}

teardown() {
	teardown_temp_dir
}

@test "every call to the forge's CLI is made under the host's lock, held for that call" {
	run fabriek_forge_admin user list
	assert_success
	run cat "$CALLS"
	assert_line --index 0 "flock $FABRIEK_FORGE_STATE/cli.lock"
	assert_line --index 1 "forgejo admin user list"
}

@test "the lock's file is made where the forge's state is, so the first call does not fail on a missing directory" {
	run fabriek_forge_admin user list
	assert_success
	[ -d "$FABRIEK_FORGE_STATE" ]
}

@test "an API call takes no lock, because the server serialises what reaches it" {
	local token="$TEST_TEMP_DIR/token"
	echo tok >"$token"
	run fabriek_forge_api http://forge/api/v1 "$token" GET /repos/acme-operator/acme
	assert_success
	run grep -c flock "$CALLS"
	assert_output 0
}

@test "a role's account carries the factory, and a name that could reach a path is refused" {
	run fabriek_forge_account acme builder
	assert_output acme-builder
	run fabriek_forge_account acme ../etc
	assert_failure
	run fabriek_forge_account "../etc" builder
	assert_failure
}
