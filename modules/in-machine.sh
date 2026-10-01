# shellcheck shell=bash
## A factory's roles live in a nixcage machine of its own (ADR-070). The
## host's fabriek-container is told which by FABRIEK_MACHINE; the guest's is
## not, since there it is the machine. One program serves both sides: what
## touches a role's state runs in the guest, what touches the host's
## services and the enter itself runs on the host.
##
## Sourced by store path into fabriek-container; the suite sources it with
## nixcage-container stubbed.

## nixcage-container with --machine when this host forwards to a machine,
## and without it where the cages are local: a verb over a cage reads the
## same on either side. No verb here reads input, and forwarding to the
## machine reads stdin all the same: inside a while-read loop it took the
## rest of the loop's lines, and prepare handed credentials to its first
## role only (2026-10-01). So it is given none.
## fabriek_nixcage <verb> [args...]
fabriek_nixcage() {
	local verb="$1"
	shift
	if [ -n "${FABRIEK_MACHINE:-}" ]; then
		nixcage-container "$verb" --machine "$FABRIEK_MACHINE" "$@" </dev/null
	else
		nixcage-container "$verb" "$@"
	fi
}

## fabriek-container in the factory's machine, as its root, with the
## factory's facts loaded by the guest's wrapper.
## fabriek_in_machine <verb> [args...]
fabriek_in_machine() {
	nixcage-container machine exec "$FABRIEK_MACHINE" fabriek-machine "$@"
}

## Whether the host may run a plan the guest made (ADR-070 point 9). The
## guest is outside the boundary, so its plan is read as data: only enter
## and exec, and no agent socket among enter's options, since which of the
## host's sockets reaches a guest is the host's to say. Everything from the
## cage's name on is the session's and is not read.
## fabriek_machine_plan_check <verb> [words...]
fabriek_machine_plan_check() {
	local verb="${1:-}"
	case "$verb" in
	enter | exec) ;;
	*)
		echo "fabriek: the machine planned '$verb', which is neither enter nor exec" >&2
		return 1
		;;
	esac
	shift
	[ "$verb" = enter ] || return 0
	while [ $# -gt 0 ]; do
		case "$1" in
		--auth-sock)
			echo "fabriek: the machine's plan names an agent socket, which is the host's to give" >&2
			return 1
			;;
		--no-agent | --no-nix-daemon | --print-argv) shift ;;
		--*) shift 2 || return 0 ;;
		*) return 0 ;;
		esac
	done
}

## An enter's options with the host's agent in place of --no-agent, NUL
## after each word: the guest planned for no agent, since it was told of
## none, and the socket is the host's.
## fabriek_machine_plan_with_agent <socket> [enter's words after the verb...]
fabriek_machine_plan_with_agent() {
	local sock="$1"
	shift
	local -a out=(--auth-sock "$sock")
	while [ $# -gt 0 ]; do
		case "$1" in
		--no-agent) shift ;;
		--no-nix-daemon | --print-argv)
			out+=("$1")
			shift
			;;
		--*)
			out+=("$1" "${2:-}")
			shift 2 || break
			;;
		*) break ;;
		esac
	done
	out+=("$@")
	printf '%s\0' "${out[@]}"
}
