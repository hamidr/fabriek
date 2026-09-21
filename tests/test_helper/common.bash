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
	export FABRIEK_LIB="$FABRIEK_ROOT/modules"
	# The operator's own config, kept out of the way of the developer's.
	export FABRIEK_CONFIG="$TEST_TEMP_DIR/fabriek.toml"
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

FABRIEK_ROOT="$NIXCAGE_ROOT"
FABRIEK_CONTAINER_BIN="${FABRIEK_ROOT}/fabriek-container"
FABRIEK_BIN="${FABRIEK_ROOT}/fabriek"

# Run the machine program as a command. It is a real script rather than a Nix
# string so the suite can drive it directly, which is what makes the seam
# something a test asserts on rather than something it crosses.
run_fabriek_container() {
	run bash "$FABRIEK_CONTAINER_BIN" "$@"
}

# Run the operator's CLI as a command.
run_fabriek() {
	run bash "$FABRIEK_BIN" "$@"
}

# The transport, stubbed. fabriek reaches its machine program as root on
# this host through sudo, for that one program and the fabriek group
# (ADR-067 point 1), with the factory named in the environment; that is the
# whole of what the CLI tests have to stand in for. The stub records the
# argv the machine program actually sees and the environment it was handed.
stub_nixcage() {
	STUB_DIR="$TEST_TEMP_DIR/bin"
	NIXCAGE_CALLS="$TEST_TEMP_DIR/nixcage-calls"
	NIXCAGE_ARGV="$TEST_TEMP_DIR/nixcage-argv"
	SUDO_ENV="$TEST_TEMP_DIR/sudo-env"
	mkdir -p "$STUB_DIR"
	export PATH="$STUB_DIR:$PATH" NIXCAGE_CALLS NIXCAGE_ARGV SUDO_ENV
	cat >"$STUB_DIR/sudo" <<STUB
#!/usr/bin/env bash
## sudo's own flags, then VAR=value words, then the program and its argv.
while [ \$# -gt 0 ]; do
	case "\$1" in
	-*) shift ;;
	*=*) printf '%s\n' "\$1" >>"$SUDO_ENV"; shift ;;
	*) break ;;
	esac
done
printf '%s ' "\$@" >>"$NIXCAGE_CALLS"
printf '\n' >>"$NIXCAGE_CALLS"
printf '%s\n' "\$@" >>"$NIXCAGE_ARGV"
## What the machine program would have printed, when a test says so.
if [ -f "$TEST_TEMP_DIR/machine-answer" ]; then cat "$TEST_TEMP_DIR/machine-answer"; fi
STUB
	chmod +x "$STUB_DIR/sudo"
}

# One line per invocation, for asserting on the shape of a call.
nixcage_calls() {
	sed 's/ $//' "$NIXCAGE_CALLS"
}

# One line per argument, for asserting that a word with spaces in it stayed
# one word.
nixcage_argv() {
	cat "$NIXCAGE_ARGV"
}

# The environment the transport handed the machine program: the factory,
# and for a hand's session the agent socket.
sudo_env() {
	cat "$SUDO_ENV"
}
