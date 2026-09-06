#!/usr/bin/env bats
# Top-level CLI dispatch: help, version, unknown commands, and the one thing
# the CLI is allowed to know about how a cage is reached.

load ../test_helper/common

setup() {
	setup_temp_dir
	stub_nixcage
}

teardown() {
	teardown_temp_dir
}

@test "no arguments shows help" {
	run_cageworks
	assert_success
	assert_output --partial "Usage:"
}

@test "every command the dispatcher accepts is in the help" {
	# Derived from the dispatcher rather than listed here, so adding a command
	# without documenting it fails instead of quietly shipping undiscoverable.
	run_cageworks help
	assert_success
	local commands
	commands="$(sed -n '/^  local command=/,/^  esac/p' "$CAGEWORKS_BIN" |
		grep -oE '^  [a-z|-]+\)' | tr -d ' )' | tr '|' '\n' | grep -vE '^(--|-)')"
	[ -n "$commands" ]
	for cmd in $commands; do
		case "$cmd" in
		help | version) continue ;;
		esac
		[[ "$output" == *"$cmd"* ]] || {
			echo "the help does not mention: $cmd"
			return 1
		}
	done
}

# nixcage's own verbs are enter, rebuild, down and status, and none of them is
# a command here. Checked on the first word of each usage line rather than on
# any word anywhere, because a subcommand may legitimately share a name with
# one of them: 'vm status' is ours, a bare 'status' would be nixcage's.
@test "the help advertises no top-level command the dispatcher would reject" {
	run_cageworks help
	assert_success
	local accepted first
	# Some cases carry their flag spellings, as 'version | --version | -v)', so
	# the label is taken up to the paren and then split rather than matched
	# whole.
	accepted="$(sed -n '/^  local command=/,/^  esac/p' "$CAGEWORKS_BIN" |
		grep -oE '^  [a-z][a-z |-]*\)' | sed 's/)$//' | tr '|' '\n' |
		sed 's/^ *//; s/ *$//' | grep -vE '^(--|-)' | grep -v '^$')"
	[ -n "$accepted" ]
	while IFS= read -r first; do
		[ -n "$first" ] || continue
		grep -qx "$first" <<<"$accepted" || {
			echo "the help advertises a command the dispatcher rejects: $first"
			return 1
		}
	done < <(printf '%s\n' "$output" |
		awk '/Commands:/ { on = 1; next } /Configuration:/ { on = 0 } on' |
		grep -oE '^  [a-z][a-z-]*' | tr -d ' ')
}

@test "version prints the version" {
	run_cageworks version
	assert_success
	assert_output --partial "cageworks "
}

@test "unknown command fails with help" {
	run_cageworks frobnicate
	assert_failure
	assert_output --partial "Unknown command"
}

@test "every guest command goes through nixcage exec and nothing else" {
	# The transport is the only thing cageworks knows about where the cages
	# are. A second way to reach them would be a second thing to keep true.
	run grep -cE '"\$NIXCAGE" exec' "$CAGEWORKS_BIN"
	assert_output "2"
	# Comments stripped: what matters is what runs.
	run bash -c "grep -vE '^[[:space:]]*#' '$CAGEWORKS_BIN' | grep -cE '(^|[^a-z])sudo[[:space:]]'"
	assert_output "0"
}

# ADR-018 had cageworks open no SSH connection at all. ADR-019 reverses that
# for one case and one only: cageworks owns the way into a machine it built
# itself. So ssh is here now, and every use of it has to carry the arguments
# that name one factory's key, port and known hosts -- never an ad hoc one.
@test "ssh reaches a machine cageworks built, and nothing else" {
	local uses named
	uses="$(grep -vE '^[[:space:]]*#' "$CAGEWORKS_BIN" |
		grep -cE '(^|[^a-z_])ssh[[:space:]]' || true)"
	named="$(grep -vE '^[[:space:]]*#' "$CAGEWORKS_BIN" |
		grep -cF 'ssh "${ssh_args[@]}"' || true)"
	[ "$uses" = "$named" ]
	[ "$uses" -ge 1 ]
}

@test "nothing here reads nixcage's own state" {
	# Reading the VM's port, key or state layout is the coupling the split
	# exists to remove.
	run grep -c 'XDG_STATE_HOME\|state/nixcage\|/var/lib/nixcage' "$CAGEWORKS_BIN"
	assert_output "0"
}
