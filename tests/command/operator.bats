#!/usr/bin/env bats
# The operator writes through the executor (ADR-039 point 1): a filed goal, a
# stop and a mirror each become one entry on the operator stream, written as
# the executor's own bus user, and the executor is the only thing that acts
# on them. A title and a body are files on the machine, never argv words the
# executor re-reads (the second invariant). valkey-cli is stubbed.

load ../test_helper/common

setup() {
	setup_temp_dir
	STATE="$TEST_TEMP_DIR/state"
	STUB_DIR="$TEST_TEMP_DIR/bin"
	ETC="$TEST_TEMP_DIR/etc"
	mkdir -p "$STATE/bus" "$STUB_DIR" "$ETC"
	PATH="$STUB_DIR:$PATH"
	export PATH STATE FABRIEK_STATE="$STATE" FABRIEK_ETC="$ETC"
	echo executor-pass >"$STATE/bus/executor"
	cat >"$ETC/bridge.json" <<'JSON'
{ "bridge": "fabriek-acme", "host": "10.77.0.1", "prefix": 24,
  "cages": { "builder": "10.77.0.10" }, "proxy": "10.77.0.1:8118",
  "forgejo": "10.77.0.1:3000", "valkey": "10.77.0.1:6379" }
JSON
	cat >"$ETC/declaration.json" <<'JSON'
{ "name": "acme", "roles": { "builder": { "command": ["pi"], "provides": ["build"] } },
  "workflows": { "ship": { "stages": [ { "needs": "design" }, { "needs": "build" } ] } } }
JSON
	cat >"$STUB_DIR/valkey-cli" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TEST_TEMP_DIR/bus-calls"
echo "1-0"
STUB
	chmod +x "$STUB_DIR/valkey-cli"
}

teardown() {
	teardown_temp_dir
}

# The json field is the last argument of the XADD.
sent_json() {
	tail -1 "$TEST_TEMP_DIR/bus-calls" | sed 's/.* json //'
}

@test "given a goal, task-file writes the title and body as files and sends a file command naming them and the first stage" {
	run_fabriek_container task-file acme ship "Add an importer" "it handles empty files"
	assert_success
	run jq -r '.verb, .stage' <<<"$(sent_json)"
	assert_line --index 0 file
	assert_line --index 1 design
	local title body
	title="$(jq -r .titleFile <<<"$(sent_json)")"
	body="$(jq -r .bodyFile <<<"$(sent_json)")"
	[ "$(cat "$title")" = "Add an importer" ]
	[ "$(cat "$body")" = "it handles empty files" ]
	[[ "$title" == "$STATE/filed/"* ]]
}

@test "the entry is written as the executor, to the operator stream, with the password from its file and not on argv" {
	run_fabriek_container task-file acme ship "t" "b"
	assert_success
	run cat "$TEST_TEMP_DIR/bus-calls"
	assert_output --partial "--user executor"
	assert_output --partial "XADD operator"
	refute_output --partial "executor-pass"
}

@test "a workflow the declaration lacks is refused before anything is written" {
	run_fabriek_container task-file acme deploy "t" "b"
	assert_failure
	assert_output --partial deploy
	[ ! -f "$TEST_TEMP_DIR/bus-calls" ]
}

@test "role-stop sends a stop naming the role" {
	run_fabriek_container role-stop acme builder
	assert_success
	run jq -c . <<<"$(sent_json)"
	assert_output '{"verb":"stop","role":"builder"}'
}

# A turn that stops answering the bus is ended at its scope (nixcage
# ADR-012): the cage's processes are gone, the task stays with the role.
@test "role-stop --now ends the cage through nixcage and sends nothing on the bus" {
	printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\n' "$TEST_TEMP_DIR/nixcage.calls" >"$STUB_DIR/nixcage-container"
	chmod +x "$STUB_DIR/nixcage-container"
	run_fabriek_container role-stop acme builder --now
	assert_success
	run cat "$TEST_TEMP_DIR/nixcage.calls"
	assert_output "stop acme-builder"
	[ ! -e "$TEST_TEMP_DIR/bus-calls" ]
}

@test "factory-mirror asks the executor to mirror, which is not a verb of the decider's" {
	run_fabriek_container factory-mirror acme
	assert_success
	run jq -c . <<<"$(sent_json)"
	assert_output '{"op":"mirror"}'
}

@test "without the executor's bus password on the machine, nothing is sent and the reason names fabriek up" {
	rm "$STATE/bus/executor"
	run_fabriek_container role-stop acme builder
	assert_failure
	assert_output --partial "fabriek up"
}

@test "factory-watch hands the connection to the relay with whatever follows the factory" {
	cat >"$STUB_DIR/fabriek-relay" <<STUB
#!/usr/bin/env bash
echo "relay \$*"
STUB
	chmod +x "$STUB_DIR/fabriek-relay"
	run_fabriek_container factory-watch acme --from 0-0
	assert_success
	assert_output "relay --from 0-0"
}
