#!/usr/bin/env bats
# What a role's agent said and ran, read from the session pi keeps in the
# role's home (ADR-038 point 2): listed newest first, printed as it is, or as
# the turns' text. Read-only; nothing here reaches a cage.

load ../test_helper/common

setup() {
	setup_temp_dir
	STATE="$TEST_TEMP_DIR/state"
	export STATE FABRIEK_STATE="$STATE" FABRIEK_LIB="$FABRIEK_ROOT/modules"
	SESSIONS="$STATE/homes/acme-builder/.pi/sessions"
	mkdir -p "$SESSIONS"
	cat >"$SESSIONS/2026-09-14T10-00-00-aaaa.jsonl" <<'JSONL'
{"type":"session","version":3,"id":"aaaa","timestamp":"2026-09-14T10:00:00.000Z","cwd":"/workspace"}
{"type":"message","id":"1","timestamp":"2026-09-14T10:00:01.000Z","message":{"role":"user","content":"You are the role builder.\nTask #7"}}
{"type":"message","id":"2","parentId":"1","timestamp":"2026-09-14T10:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"I will write the test first."},{"type":"toolCall","name":"edit"}]}}
{"type":"message","id":"3","parentId":"2","timestamp":"2026-09-14T10:00:03.000Z","message":{"role":"toolResult","toolName":"edit","content":[{"type":"text","text":"test-first guard (run-before-code): src/a.py is production code"}],"isError":true}}
JSONL
	sleep 1
	printf '{"type":"session","version":3,"id":"bbbb","timestamp":"2026-09-14T11:00:00.000Z","cwd":"/workspace"}\n' >"$SESSIONS/2026-09-14T11-00-00-bbbb.jsonl"
}

teardown() {
	teardown_temp_dir
}

run_fabriek_container() {
	run bash "$FABRIEK_ROOT/fabriek-container" "$@"
}

@test "with no session named, the role's sessions are listed newest first with their size" {
	run_fabriek_container role-transcript acme builder
	assert_success
	assert_line --index 0 --partial "2026-09-14T11-00-00-bbbb.jsonl"
	assert_line --index 1 --partial "2026-09-14T10-00-00-aaaa.jsonl"
}

@test "a named session is printed as pi wrote it" {
	run_fabriek_container role-transcript acme builder 2026-09-14T10-00-00-aaaa.jsonl
	assert_success
	assert_line --index 0 --partial '"type":"session"'
	[ "${#lines[@]}" -eq 4 ]
}

@test "with --text, a session is the turns' text: who said it, the tools called, and the results" {
	run_fabriek_container role-transcript acme builder 2026-09-14T10-00-00-aaaa.jsonl --text
	assert_success
	assert_line --index 0 "user: You are the role builder."
	assert_line --index 1 "Task #7"
	assert_line --index 2 "assistant: I will write the test first."
	assert_line --index 3 "assistant calls edit"
	assert_line --index 4 "edit (error): test-first guard (run-before-code): src/a.py is production code"
}

@test "a session name that could leave the sessions directory is refused" {
	run_fabriek_container role-transcript acme builder ../../../etc/passwd
	assert_failure
	assert_output --partial "not a session name"
}

@test "a role with no sessions yet says so rather than failing" {
	run_fabriek_container role-transcript acme reviewer
	assert_success
	assert_output --partial "no sessions"
}
