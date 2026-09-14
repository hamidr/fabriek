#!/usr/bin/env bats
# The console (ADR-039 point 3): the TUI on the operator's host, over the
# relay. Its every key is a launcher command, so it has to be told which
# launcher: the one that started it, by path, because "fabriek" is on no
# PATH the operator is obliged to have. Found on a console that died with
# "spawn fabriek ENOENT" the moment it opened.

load ../test_helper/common

setup() {
	setup_temp_dir
	stub_nixcage
	printf 'builder\nreviewer\n' >"$TEST_TEMP_DIR/machine-answer"
	cat >"$STUB_DIR/fabriek-tui" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >"$TEST_TEMP_DIR/tui-args"
printf '%s\\n' "\${FABRIEK_CLI:-}" >"$TEST_TEMP_DIR/tui-cli"
EOF
	chmod +x "$STUB_DIR/fabriek-tui"
}

teardown() {
	teardown_temp_dir
}

@test "console starts the TUI with the factory and its roles, told the launcher that started it by path" {
	run_fabriek -f acme console
	assert_success
	run cat "$TEST_TEMP_DIR/tui-args"
	assert_output "acme builder reviewer"
	run cat "$TEST_TEMP_DIR/tui-cli"
	assert_output "$(readlink -f "$FABRIEK_BIN")"
}
