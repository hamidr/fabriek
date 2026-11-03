#!/usr/bin/env bats
# A credential file that changed reaches the proxy without an up (ADR-072
# point 3): credential-refresh copies each declared file into the state of
# every factory whose rendered endpoints hold its host, has the factory's
# egress unit compose its header again, reloads nginx, and only then touches
# the stamp the credential's age is read from. It never restarts nginx.
#
# systemctl and chown are stubbed; the operator's config reader is real.

load ../test_helper/common
load ../test_helper/stubs

setup() {
	setup_temp_dir
	STUB_DIR="$TEST_TEMP_DIR/bin"
	CALLS="$TEST_TEMP_DIR/calls"
	FACTS="$TEST_TEMP_DIR/facts"
	mkdir -p "$STUB_DIR" "$CALLS" "$FACTS"
	PATH="$STUB_DIR:$PATH"
	export PATH

	local f
	for f in acme widgets; do
		mkdir -p "$TEST_TEMP_DIR/$f/state" "$TEST_TEMP_DIR/$f/etc"
		cat >"$FACTS/$f.env" <<EOF
FABRIEK_FACTORY=$f
FABRIEK_STATE=$TEST_TEMP_DIR/$f/state
FABRIEK_ETC=$TEST_TEMP_DIR/$f/etc
EOF
	done
	# acme reaches the gateway and anthropic; widgets reaches anthropic only.
	echo '{"credentials":{"gw.example.test":"authorization","api.anthropic.com":"x-api-key"},"models":{}}' >"$TEST_TEMP_DIR/acme/etc/endpoints.json"
	echo '{"credentials":{"api.anthropic.com":"x-api-key"},"models":{}}' >"$TEST_TEMP_DIR/widgets/etc/endpoints.json"

	mkdir -p "$TEST_TEMP_DIR/creds"
	echo "Bearer first" >"$TEST_TEMP_DIR/creds/gateway"
	echo "sk-ant" >"$TEST_TEMP_DIR/creds/anthropic"
	export FABRIEK_CONFIG="$TEST_TEMP_DIR/config.toml"
	cat >"$FABRIEK_CONFIG" <<TOML
[caps]
egress = ["gateway", "api.anthropic.com"]

[endpoints.gateway]
host = "gw.example.test"
provider = "anthropic"
header = "authorization"
file = "$TEST_TEMP_DIR/creds/gateway"
models.default = "claude-sonnet-5"

[credentials."api.anthropic.com"]
header = "x-api-key"
file = "$TEST_TEMP_DIR/creds/anthropic"
TOML
	export FABRIEK_FACTORIES="$FACTS"
	stub_record systemctl "$CALLS/systemctl"
	stub_record chown "$CALLS/chown"
}

teardown() {
	teardown_temp_dir
}

perms() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }

@test "a changed credential file reaches every factory whose endpoints hold its host, and no other" {
	run_fabriek_container credential-refresh
	assert_success
	run cat "$TEST_TEMP_DIR/acme/state/egress/gw.example.test"
	assert_output "Bearer first"
	[ ! -e "$TEST_TEMP_DIR/widgets/state/egress/gw.example.test" ]
	[ -f "$TEST_TEMP_DIR/widgets/state/egress/api.anthropic.com" ]
	echo "Bearer second" >"$TEST_TEMP_DIR/creds/gateway"
	run_fabriek_container credential-refresh
	assert_success
	run cat "$TEST_TEMP_DIR/acme/state/egress/gw.example.test"
	assert_output "Bearer second"
	run perms "$TEST_TEMP_DIR/acme/state/egress/gw.example.test"
	assert_output 400
}

@test "a refresh has each factory's egress unit compose its headers again and reloads nginx, never restarting either" {
	run_fabriek_container credential-refresh
	assert_success
	run cat "$CALLS/systemctl"
	assert_line 'reload-or-restart fabriek-acme-egress-credentials.service'
	assert_line 'reload-or-restart fabriek-widgets-egress-credentials.service'
	assert_line 'reload nginx.service'
	refute_output --partial 'restart nginx'
	refute_output --regexp '^restart '
}

@test "the stamp moves only when the refresh went through" {
	run_fabriek_container credential-refresh
	assert_success
	local stamp="$TEST_TEMP_DIR/acme/state/egress-age/gw.example.test"
	[ -f "$stamp" ]
	touch -t 202001010000 "$stamp"
	rm "$TEST_TEMP_DIR/creds/gateway"
	run_fabriek_container credential-refresh
	assert_failure
	assert_output --partial "the credential for gw.example.test is not at"
	[ $(($(date +%s) - $(mtime "$stamp"))) -gt 3600 ]
	run cat "$TEST_TEMP_DIR/acme/state/egress/gw.example.test"
	assert_output "Bearer first"
}

@test "a stamp is readable by the executor and the credential is the proxy user's alone" {
	run_fabriek_container credential-refresh
	assert_success
	run perms "$TEST_TEMP_DIR/acme/state/egress-age/gw.example.test"
	assert_output 644
	run grep -c "fabriek-egress:fabriek-egress" "$CALLS/chown"
	assert_output 3
}

@test "a factory not rendered yet has nothing to refresh and does not fail the others" {
	rm "$TEST_TEMP_DIR/widgets/etc/endpoints.json"
	run_fabriek_container credential-refresh
	assert_success
	[ ! -e "$TEST_TEMP_DIR/widgets/state/egress" ]
	[ -f "$TEST_TEMP_DIR/acme/state/egress/gw.example.test" ]
}

@test "factory-credentials says each credential's age in seconds from its stamp, and never for one with none" {
	run_fabriek_container credential-refresh
	assert_success
	touch -t 202001010000 "$TEST_TEMP_DIR/acme/state/egress-age/gw.example.test"
	rm "$TEST_TEMP_DIR/acme/state/egress-age/api.anthropic.com"
	FABRIEK_FACTORY=acme run_fabriek_container factory-credentials acme
	assert_success
	assert_line --regexp '^api\.anthropic\.com	never$'
	assert_line --regexp '^gw\.example\.test	[0-9]{9,}$'
	run_fabriek_container credential-refresh
	FABRIEK_FACTORY=widgets run_fabriek_container factory-credentials widgets
	assert_success
	assert_line --regexp '^api\.anthropic\.com	[0-9]{1,2}$'
}
