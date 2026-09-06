#!/usr/bin/env bash
# Shared test helper for nixcage bats tests

NIXCAGE_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
NIXCAGE_BIN="${NIXCAGE_ROOT}/nixcage"

# Load bats libraries via BATS_LIB_PATH (set by nix devShell)
if [[ -n "${BATS_LIB_PATH:-}" ]]; then
	IFS=':' read -ra _lib_dirs <<<"$BATS_LIB_PATH"
	for _dir in "${_lib_dirs[@]}"; do
		[[ -f "$_dir/bats-support/load.bash" ]] && load "$_dir/bats-support/load.bash"
	done
	for _dir in "${_lib_dirs[@]}"; do
		[[ -f "$_dir/bats-assert/load.bash" ]] && load "$_dir/bats-assert/load.bash"
	done
	unset _lib_dirs _dir
fi

# Isolate every test from the real user state and config. The OS is pinned
# to macos so the suite behaves identically on Linux CI/dev machines;
# linux_mode.bats overrides it.
setup_temp_dir() {
	TEST_TEMP_DIR="$(mktemp -d)"
	export TEST_TEMP_DIR
	export NIXCAGE_OS=macos
	export XDG_STATE_HOME="$TEST_TEMP_DIR/state"
	export NIXCAGE_FLAKE="$TEST_TEMP_DIR/config"
	# An agent inherited from the machine running the suite would make the
	# forwarding tests depend on the developer's own session.
	unset SSH_AUTH_SOCK
	# Both programs source their shell modules by store path. In the suite that
	# path is the working tree, which is what lets bats drive them directly.
	export CAGEWORKS_LIB="$CAGEWORKS_ROOT/modules"
	# The operator's own config, kept out of the way of the developer's.
	export CAGEWORKS_CONFIG="$TEST_TEMP_DIR/cageworks.toml"
	mkdir -p "$XDG_STATE_HOME/nixcage" "$NIXCAGE_FLAKE"
}

teardown_temp_dir() {
	if [[ -n "${TEST_TEMP_DIR:-}" && -d "$TEST_TEMP_DIR" ]]; then
		chmod -R u+w "$TEST_TEMP_DIR" 2>/dev/null || true
		rm -rf "$TEST_TEMP_DIR"
	fi
}

# Source nixcage functions without executing main
source_nixcage() {
	source "$NIXCAGE_BIN"
}

# Run nixcage as a command (not sourced)
run_nixcage() {
	run bash "$NIXCAGE_BIN" "$@"
}

# Write the build-time cache the CLI reads at runtime.
write_cache() {
	local port="${1:-22022}"
	local roots="${2:-$TEST_TEMP_DIR/src}"
	cat >"$XDG_STATE_HOME/nixcage/cache" <<EOF
SSH_PORT=$port
WORKSPACE_ROOTS=$roots
EOF
}

CAGEWORKS_ROOT="$NIXCAGE_ROOT"
CAGEWORKS_CONTAINER_BIN="${CAGEWORKS_ROOT}/cageworks-container"
CAGEWORKS_BIN="${CAGEWORKS_ROOT}/cageworks"

# Run the guest program as a command. It is a real script rather than a Nix
# string so the suite can drive it directly, which is what makes the seam
# something a test asserts on rather than something it crosses.
run_cageworks_container() {
	run bash "$CAGEWORKS_CONTAINER_BIN" "$@"
}

# Run the operator's CLI as a command.
run_cageworks() {
	run bash "$CAGEWORKS_BIN" "$@"
}

# The transport, stubbed. cageworks reaches its guest program through
# 'nixcage exec' and knows nothing else about where the cages are, so this is
# the whole of what the CLI tests have to stand in for.
stub_nixcage() {
	STUB_DIR="$TEST_TEMP_DIR/bin"
	NIXCAGE_CALLS="$TEST_TEMP_DIR/nixcage-calls"
	NIXCAGE_ARGV="$TEST_TEMP_DIR/nixcage-argv"
	mkdir -p "$STUB_DIR"
	export PATH="$STUB_DIR:$PATH" NIXCAGE_CALLS NIXCAGE_ARGV
	cat >"$STUB_DIR/nixcage" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"$NIXCAGE_CALLS"
printf '%s\n' "\$@" >>"$NIXCAGE_ARGV"
STUB
	chmod +x "$STUB_DIR/nixcage"
}

# One line per invocation, for asserting on the shape of a call.
nixcage_calls() {
	cat "$NIXCAGE_CALLS"
}

# One line per argument, for asserting that a word with spaces in it stayed
# one word.
nixcage_argv() {
	cat "$NIXCAGE_ARGV"
}
