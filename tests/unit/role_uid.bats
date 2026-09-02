#!/usr/bin/env bats
# A factory role is allocated a uid from the declared range (ADR-010).

load ../test_helper/common

setup() {
	setup_temp_dir
	STORE="$TEST_TEMP_DIR/role-uids"
	# shellcheck source=../../modules/role-uid.sh
	source "$NIXCAGE_ROOT/modules/role-uid.sh"
}

teardown() {
	teardown_temp_dir
}

@test "the first role in an empty factory gets the base of the range" {
	run nixcage_role_uid "$STORE" 700000 64 builder
	assert_success
	assert_output "700000"
}

@test "asking twice for the same role returns the uid it already has" {
	first="$(nixcage_role_uid "$STORE" 700000 64 builder)"
	second="$(nixcage_role_uid "$STORE" 700000 64 builder)"
	[ "$first" = "$second" ]
}

@test "a second role gets a different uid" {
	a="$(nixcage_role_uid "$STORE" 700000 64 builder)"
	b="$(nixcage_role_uid "$STORE" 700000 64 reviewer)"
	[ "$a" != "$b" ]
}

@test "an allocation survives into a later invocation" {
	first="$(nixcage_role_uid "$STORE" 700000 64 builder)"
	nixcage_role_uid "$STORE" 700000 64 reviewer >/dev/null
	again="$(nixcage_role_uid "$STORE" 700000 64 builder)"
	[ "$first" = "$again" ]
}

@test "a uid is never reissued after its role is forgotten" {
	a="$(nixcage_role_uid "$STORE" 700000 64 builder)"
	nixcage_role_forget "$STORE" builder
	b="$(nixcage_role_uid "$STORE" 700000 64 newcomer)"
	[ "$a" != "$b" ]
}

@test "a forgotten role that returns does not get its old uid back" {
	a="$(nixcage_role_uid "$STORE" 700000 64 builder)"
	nixcage_role_forget "$STORE" builder
	b="$(nixcage_role_uid "$STORE" 700000 64 builder)"
	[ "$a" != "$b" ]
}

@test "exhausting the range fails loudly rather than colliding" {
	nixcage_role_uid "$STORE" 700000 2 one >/dev/null
	nixcage_role_uid "$STORE" 700000 2 two >/dev/null
	run nixcage_role_uid "$STORE" 700000 2 three
	assert_failure
	assert_output --partial "uid range"
}

@test "a role name that could escape the store is refused" {
	run nixcage_role_uid "$STORE" 700000 64 "bad name"
	assert_failure
	run nixcage_role_uid "$STORE" 700000 64 "../escape"
	assert_failure
}

@test "concurrent allocations never hand out the same uid" {
	for role in a b c d e f g h; do
		nixcage_role_uid "$STORE" 700000 64 "$role" >>"$TEST_TEMP_DIR/out" &
	done
	wait
	total="$(wc -l <"$TEST_TEMP_DIR/out" | tr -d ' ')"
	distinct="$(sort -u "$TEST_TEMP_DIR/out" | wc -l | tr -d ' ')"
	[ "$total" = "8" ]
	[ "$distinct" = "8" ]
}

@test "a session with no role keeps the ordinary root login" {
	run nixcage_role_login ""
	assert_success
	assert_output "root"
}

@test "a role session is named after the role inside the cage" {
	run nixcage_role_login builder
	assert_success
	assert_output "builder"
}

@test "the passwd line names uid 0 after the role" {
	run nixcage_role_passwd builder
	assert_success
	assert_line --index 0 "builder:x:0:0:builder:/root:/bin/sh"
	assert_line --index 1 "nobody:x:65534:65534:nobody:/var/empty:/bin/sh"
}

@test "an invalid role name cannot reach the passwd file" {
	run nixcage_role_passwd "root:x:0:0::/:/bin/sh"
	assert_failure
}
