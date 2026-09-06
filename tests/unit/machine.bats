#!/usr/bin/env bats
# Where a factory's machine lives on the operator's host, what lets cageworks
# in, and which machines are here (ADR-019).
#
# cageworks owns the transport because it owns the VM, so the key and the port
# are its to make and its to keep apart: no factory reads another factory's way
# in. This is the bookkeeping half of that, and it is the half that does not
# need a hypervisor to be true.

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/names.sh
	source "$CAGEWORKS_ROOT/modules/names.sh"
	# shellcheck source=../../modules/machine.sh
	source "$CAGEWORKS_ROOT/modules/machine.sh"
	MACHINES="$TEST_TEMP_DIR/machines"
	export CAGEWORKS_MACHINES="$MACHINES"
}

teardown() {
	teardown_temp_dir
}

@test "a factory's machine has a place of its own, named after it" {
	run cageworks_machine_dir acme
	assert_success
	assert_output "$MACHINES/acme"
}

@test "a name that could reach out of that place is refused" {
	run cageworks_machine_dir "../../etc"
	assert_failure
}

@test "two factories are not the same machine" {
	local one two
	one="$(cageworks_machine_dir acme)"
	two="$(cageworks_machine_dir widgets)"
	[ "$one" != "$two" ]
}

@test "preparing a machine makes its place, and doing it twice changes nothing" {
	run cageworks_machine_ensure acme
	assert_success
	[ -d "$MACHINES/acme" ]

	local first
	first="$(cat "$MACHINES/acme/port")"
	run cageworks_machine_ensure acme
	assert_success
	[ "$(cat "$MACHINES/acme/port")" = "$first" ]
}

@test "a machine gets a key of its own, readable by nobody else" {
	cageworks_machine_ensure acme
	[ -f "$MACHINES/acme/id_ed25519" ]
	[ -f "$MACHINES/acme/id_ed25519.pub" ]
	# GNU stat in the devShell, BSD stat on a bare macOS shell.
	local mode
	mode="$(stat -c '%a' "$MACHINES/acme/id_ed25519" 2>/dev/null ||
		stat -f '%Lp' "$MACHINES/acme/id_ed25519")"
	[ "$mode" = "600" ]
}

# The whole point of a key per factory. One machine's way in is not another's,
# so a factory cannot reach a factory it was not told about.
@test "no factory holds another factory's way in" {
	cageworks_machine_ensure acme
	cageworks_machine_ensure widgets
	run diff "$MACHINES/acme/id_ed25519.pub" "$MACHINES/widgets/id_ed25519.pub"
	assert_failure
}

@test "a machine keeps the key it was given rather than a new one each time" {
	cageworks_machine_ensure acme
	local before
	before="$(cat "$MACHINES/acme/id_ed25519.pub")"
	cageworks_machine_ensure acme
	[ "$(cat "$MACHINES/acme/id_ed25519.pub")" = "$before" ]
}

@test "a machine gets a port, and it is one nothing else here was given" {
	cageworks_machine_ensure acme
	cageworks_machine_ensure widgets
	local a w
	a="$(cageworks_machine_port acme)"
	w="$(cageworks_machine_port widgets)"
	[ -n "$a" ] && [ -n "$w" ]
	[ "$a" != "$w" ]
}

@test "a port is a port" {
	cageworks_machine_ensure acme
	local port
	port="$(cageworks_machine_port acme)"
	[ "$port" -ge 1024 ]
	[ "$port" -le 65535 ]
}

@test "the machines here are the ones that were prepared, in a stable order" {
	cageworks_machine_ensure widgets
	cageworks_machine_ensure acme
	run cageworks_machine_list
	assert_success
	assert_line --index 0 "acme"
	assert_line --index 1 "widgets"
}

@test "nothing prepared means no machines, and that is not an error" {
	run cageworks_machine_list
	assert_success
	assert_output ""
}

@test "a machine nobody prepared has no port to report" {
	run cageworks_machine_port ghost
	assert_failure
	assert_output --partial "ghost"
}

# ADR-019 point 3: the disk outlives every transition but the one that exists
# to remove it, so nothing here removes it as a side effect of anything.
@test "preparing a machine again leaves what it is holding alone" {
	cageworks_machine_ensure acme
	printf 'work\n' >"$MACHINES/acme/disk.img"
	cageworks_machine_ensure acme
	run cat "$MACHINES/acme/disk.img"
	assert_output "work"
}

@test "the machines live where the operator's own state lives" {
	unset CAGEWORKS_MACHINES
	XDG_STATE_HOME="$TEST_TEMP_DIR/xdg" run cageworks_machine_root
	assert_success
	assert_output "$TEST_TEMP_DIR/xdg/cageworks/machines"
}

# The fix for a machine dying with the command that started it. nohup only
# refuses SIGHUP and leaves the process in the caller's process group, where
# anything signalling the group reaches it anyway.
# Read as a process group rather than a session id, because macOS ps has no
# sid keyword and a new session brings a new group with it either way. A plain
# background job keeps the caller's group, which is the case this rules out.
@test "a machine is spawned out of the process group that started it" {
	local pid group mine
	pid="$(cageworks_machine_spawn "$TEST_TEMP_DIR/log" sleep 5)"
	[ -n "$pid" ]
	group="$(ps -o pgid= -p "$pid" | tr -d ' ')"
	mine="$(ps -o pgid= -p $$ | tr -d ' ')"
	kill "$pid" 2>/dev/null || true
	[ -n "$group" ]
	[ -n "$mine" ]
	[ "$group" != "$mine" ]
}

@test "what a spawned machine writes goes to the log it was given" {
	local pid
	pid="$(cageworks_machine_spawn "$TEST_TEMP_DIR/log" sh -c 'echo booted')"
	sleep 1
	kill "$pid" 2>/dev/null || true
	run cat "$TEST_TEMP_DIR/log"
	assert_output "booted"
}
