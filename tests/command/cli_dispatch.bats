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
	run_fabriek
	assert_success
	assert_output --partial "Usage:"
}

@test "every command the dispatcher accepts is in the help" {
	# Derived from the dispatcher rather than listed here, so adding a command
	# without documenting it fails instead of quietly shipping undiscoverable.
	run_fabriek help
	assert_success
	local commands
	commands="$(sed -n '/^  local command=/,/^  esac/p' "$FABRIEK_BIN" |
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
	run_fabriek help
	assert_success
	local accepted first
	# Some cases carry their flag spellings, as 'version | --version | -v)', so
	# the label is taken up to the paren and then split rather than matched
	# whole.
	accepted="$(sed -n '/^  local command=/,/^  esac/p' "$FABRIEK_BIN" |
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
	run_fabriek version
	assert_success
	assert_output --partial "fabriek "
}

@test "unknown command fails with help" {
	run_fabriek frobnicate
	assert_failure
	[ "$status" -eq 2 ]
	assert_output --partial "unknown verb"
}

# ADR-067 point 1: the machine program runs on this host as root, reached
# through sudo for that one program, with the factory named in the
# environment. That is the only transport, and every use of it goes
# through machine(), so one place carries the factory and the words.
@test "every machine command reaches the machine program through sudo, and through nothing else" {
	local uses named
	uses="$(grep -vE '^[[:space:]]*#' "$FABRIEK_BIN" |
		grep -cE '(^|[^a-z_])sudo[[:space:]]' || true)"
	named="$(grep -vE '^[[:space:]]*#' "$FABRIEK_BIN" |
		grep -cF 'sudo "${sudo_args[@]}"' || true)"
	[ "$uses" = "$named" ]
	[ "$uses" -ge 1 ]
	run bash -c "grep -vE '^[[:space:]]*#' '$FABRIEK_BIN' | grep -cE '(^|[^a-z_])ssh[[:space:]]'"
	assert_output "0"
	run bash -c "grep -vE '^[[:space:]]*#' '$FABRIEK_BIN' | grep -cE '\"\\\$NIXCAGE\" exec'"
	assert_output "0"
}

# A machine verb carries a task's acceptance and a role's outcome as words.
# sudo passes argv through as argv, so nothing is quoted for a shell and
# nothing is re-split on the way; the NUL framing ssh needed is gone.
@test "a machine command's words survive the transport as words" {
	run bash -c "grep -vE '^[[:space:]]*#' '$FABRIEK_BIN' | grep -c 'xargs -0'"
	assert_output "0"
}

@test "nothing here reads nixcage's own state" {
	# Reading the VM's port, key or state layout is the coupling the split
	# exists to remove.
	run grep -c 'XDG_STATE_HOME\|state/nixcage\|/var/lib/nixcage' "$FABRIEK_BIN"
	assert_output "0"
}
