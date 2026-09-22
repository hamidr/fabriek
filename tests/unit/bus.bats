#!/usr/bin/env bats
# The account's users, as prepare writes them for the host's one server
# (ADR-069 points 3 and 4). nats-server and natscli are stubbed: what is
# under test is the file, its permissions and the order the reload is asked
# in, not the server's own reading of it.

load ../test_helper/common

setup() {
	setup_temp_dir
	STUB_DIR="$TEST_TEMP_DIR/bin"
	CALLS="$TEST_TEMP_DIR/calls"
	STATE="$TEST_TEMP_DIR/state"
	ETC="$TEST_TEMP_DIR/etc"
	mkdir -p "$STUB_DIR" "$STATE/bus" "$ETC"
	PATH="$STUB_DIR:$PATH"
	export PATH CALLS
	export FABRIEK_BUS_CONFIG_DIR="$TEST_TEMP_DIR/conf"
	mkdir -p "$FABRIEK_BUS_CONFIG_DIR"
	# natscli's hasher: the password reaches it in the environment, and
	# what comes back says nothing about it.
	cat >"$STUB_DIR/nats" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$* password=\${PASSWORD:-}" >>"$CALLS"
echo '\$2a\$11\$thisisthesuiteshash'
EOF
	cat >"$STUB_DIR/nats-server" <<EOF
#!/usr/bin/env bash
printf 'nats-server %s\n' "\$*" >>"$CALLS"
[ -e "$TEST_TEMP_DIR/invalid" ] && exit 1
exit 0
EOF
	cat >"$STUB_DIR/systemctl" <<EOF
#!/usr/bin/env bash
printf 'systemctl %s\n' "\$*" >>"$CALLS"
EOF
	chmod +x "$STUB_DIR"/*
	cat >"$ETC/declaration.json" <<'JSON'
{ "name": "acme", "roles": { "dev": { "command": ["pi"] }, "reviewer": { "command": ["pi"] } } }
JSON
	# shellcheck source=../../modules/names.sh
	source "$FABRIEK_ROOT/modules/names.sh"
	# shellcheck source=../../modules/forge.sh
	source "$FABRIEK_ROOT/modules/forge.sh"
	# shellcheck source=../../modules/bus.sh
	source "$FABRIEK_ROOT/modules/bus.sh"
	for user in dev reviewer decider executor probes; do
		fabriek_bus_ensure_password "$STATE" "$user"
	done
}

teardown() {
	teardown_temp_dir
}

## The file without the line that says who wrote it, which is the JSON.
users_json() {
	sed '1d; s/^users = //' "$ETC/nats-users.conf"
}

@test "every user of the account is written, named for the factory, with a hash and never a password" {
	run fabriek_bus_render_users acme "$STATE" "$ETC" "$ETC/declaration.json"
	assert_success
	run jq -r '[.[].user] | sort | join(",")' <<<"$(users_json)"
	assert_output "acme-decider,acme-dev,acme-executor,acme-probes,acme-reviewer"
	run grep -c -F "$(cat "$STATE/bus/dev")" "$ETC/nats-users.conf"
	assert_output 0
	run jq -r '[.[] | select(.password | startswith("$2a$"))] | length' <<<"$(users_json)"
	assert_output 5
}

@test "a role may say its own control, findings and events, and pull its own mailbox and every role's findings" {
	fabriek_bus_render_users acme "$STATE" "$ETC" "$ETC/declaration.json"
	run jq -r '.[] | select(.user == "acme-dev") | .permissions.publish.allow | join(",")' <<<"$(users_json)"
	assert_output --partial "control.dev"
	assert_output --partial "findings.dev"
	assert_output --partial "events.dev"
	assert_output --partial '$JS.API.CONSUMER.MSG.NEXT.mailbox-dev.*'
	assert_output --partial '$JS.API.CONSUMER.MSG.NEXT.findings.*'
	refute_output --partial "control.reviewer"
	refute_output --partial "mailbox-reviewer"
}

@test "a role subscribes its own inbox and no other's, which is where a reply comes back" {
	fabriek_bus_render_users acme "$STATE" "$ETC" "$ETC/declaration.json"
	run jq -r '.[] | select(.user == "acme-dev") | .permissions.subscribe.allow | join(",")' <<<"$(users_json)"
	assert_output "_INBOX.acme-dev.>"
}

@test "the decider asks in one verb and reads every stream; the probes write one and read none" {
	fabriek_bus_render_users acme "$STATE" "$ETC" "$ETC/declaration.json"
	run jq -c '.[] | select(.user == "acme-decider") | .permissions.publish.allow' <<<"$(users_json)"
	assert_output --partial '"commands"'
	assert_output --partial '$JS.API.CONSUMER.MSG.NEXT.>'
	refute_output --partial '"control.dev"'
	run jq -c '.[] | select(.user == "acme-probes") | .permissions.publish.allow' <<<"$(users_json)"
	assert_output '["probes"]'
}

@test "the executor is the account's one manager, and may say and hear everything in it" {
	fabriek_bus_render_users acme "$STATE" "$ETC" "$ETC/declaration.json"
	run jq -c '.[] | select(.user == "acme-executor") | [.permissions.publish.allow, .permissions.subscribe.allow]' <<<"$(users_json)"
	assert_output '[[">"],[">"]]'
}

@test "a user whose password is not written yet is left out, which is a factory never brought up" {
	rm "$STATE/bus/reviewer"
	fabriek_bus_render_users acme "$STATE" "$ETC" "$ETC/declaration.json"
	run jq -r '[.[].user] | join(",")' <<<"$(users_json)"
	refute_output --partial "acme-reviewer"
}

# ADR-069 point 3, as one server makes it true: a file the server cannot
# read would be read by every factory's reload, so what a factory writes is
# checked before it is put in place and the one in place stays as it was.
@test "a file the server cannot read is never put in place, and nothing is reloaded" {
	fabriek_bus_render_users acme "$STATE" "$ETC" "$ETC/declaration.json"
	local kept
	kept="$(cat "$ETC/nats-users.conf")"
	touch "$TEST_TEMP_DIR/invalid"
	run fabriek_bus_render_users acme "$STATE" "$ETC" "$ETC/declaration.json"
	assert_failure
	assert_output --partial "left as it was"
	[ "$(cat "$ETC/nats-users.conf")" = "$kept" ]
	[ ! -e "$ETC/nats-users.conf.new" ]
}

@test "the configuration is checked before the server is asked to read it again" {
	run fabriek_bus_reload
	assert_success
	run cat "$CALLS"
	assert_line --index 0 "nats-server -t -c $FABRIEK_BUS_CONFIG_DIR/nats.conf"
	assert_line --index 1 "systemctl reload nats.service"
}

# One server reads one configuration: a file this factory did not write and
# nobody has repaired holds up every factory's reload, and the refusal says
# where to look rather than blaming the factory that asked.
@test "a configuration the server cannot read stops the reload, and says it may be another factory's" {
	touch "$TEST_TEMP_DIR/invalid"
	run fabriek_bus_reload
	assert_failure
	assert_output --partial "nothing was reloaded"
	assert_output --partial "another factory's users"
	run grep -c "systemctl" "$CALLS"
	assert_output 0
}
