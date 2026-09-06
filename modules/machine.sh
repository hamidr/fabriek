# shellcheck shell=bash
## Where a factory's machine lives on the operator's host (ADR-019).
##
## cageworks builds and runs one VM per factory, so it owns the way into each:
## a keypair and a forwarded port made here and kept beside that factory's disk.
## No factory reads another factory's way in, which is a property of these
## directories being separate rather than of anything being careful.
##
## This is the bookkeeping half of a machine, and it is deliberately the half
## that needs no hypervisor to be true: where the disk is, what the key is, what
## port it answers on, and which machines this host has. Building and booting
## one is elsewhere and depends on all of this.

## Where every machine on this host lives. CAGEWORKS_MACHINES overrides it,
## which is what the suite uses and what an operator running two sets of them
## needs.
cageworks_machine_root() {
	if [ -n "${CAGEWORKS_MACHINES:-}" ]; then
		printf '%s\n' "$CAGEWORKS_MACHINES"
		return 0
	fi
	printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/cageworks/machines"
}

## One factory's machine. The name is checked here because it becomes a path,
## and refusing it where it is read is what stops anything downstream escaping
## it.
cageworks_machine_dir() {
	local factory="$1"
	cageworks_name_ok "$factory" || {
		echo "cageworks: invalid factory name: $factory" >&2
		return 1
	}
	printf '%s/%s\n' "$(cageworks_machine_root)" "$factory"
}

## A port nothing else on this host was given. Chosen once and kept, because a
## machine that answers somewhere new every time it is prepared is one nothing
## can hold a connection to.
cageworks_machine_allocate_port() {
	local taken port dir
	taken=" $(cageworks_machine_list | while IFS= read -r factory; do
		dir="$(cageworks_machine_dir "$factory")" || continue
		[ -f "$dir/port" ] && cat "$dir/port"
	done | tr '\n' ' ')"

	for port in $(seq 22100 22999); do
		case "$taken" in
		*" $port "*) continue ;;
		esac
		printf '%s\n' "$port"
		return 0
	done
	echo "cageworks: no free port left for a machine on this host" >&2
	return 1
}

## Make a factory's machine ready to be built and booted: its place, its key
## and its port. Idempotent, and it touches nothing it did not create, because
## the disk beside these outlives every transition but the one that removes it
## (ADR-019 point 3).
cageworks_machine_ensure() {
	local factory="$1" dir port
	dir="$(cageworks_machine_dir "$factory")" || return 1
	mkdir -p "$dir"

	if [ ! -f "$dir/id_ed25519" ]; then
		ssh-keygen -q -t ed25519 -N "" -C "cageworks-$factory" -f "$dir/id_ed25519" ||
			return 1
		chmod 600 "$dir/id_ed25519"
	fi

	if [ ! -f "$dir/port" ]; then
		port="$(cageworks_machine_allocate_port)" || return 1
		printf '%s\n' "$port" >"$dir/port.new"
		mv "$dir/port.new" "$dir/port"
	fi

	printf '%s\n' "$dir"
}

## What port a factory's machine answers on.
cageworks_machine_port() {
	local factory="$1" dir
	dir="$(cageworks_machine_dir "$factory")" || return 1
	if [ ! -f "$dir/port" ]; then
		echo "cageworks: $factory has no machine prepared here" >&2
		return 1
	fi
	cat "$dir/port"
}

## The private key that reaches a factory's machine, and nothing else's.
cageworks_machine_key() {
	local factory="$1" dir
	dir="$(cageworks_machine_dir "$factory")" || return 1
	if [ ! -f "$dir/id_ed25519" ]; then
		echo "cageworks: $factory has no machine prepared here" >&2
		return 1
	fi
	printf '%s\n' "$dir/id_ed25519"
}

## The machines on this host, one per line, in a stable order. A host with none
## has none, which is not an error: it is what a host looks like before the
## first factory is started.
cageworks_machine_list() {
	local root path
	root="$(cageworks_machine_root)"
	[ -d "$root" ] || return 0
	for path in "$root"/*; do
		[ -d "$path" ] || continue
		basename "$path"
	done | sort
}

## Start a command in a session of its own, detached from whatever started it.
##
## A machine has to outlive the command that booted it, and backgrounding is
## not enough: nohup only refuses SIGHUP, and the process stays in the caller's
## process group where anything that signals the group reaches it too. setsid
## is the right tool and is not on macOS, so perl is asked for the same call.
cageworks_machine_spawn() {
	local log="$1"
	shift
	if command -v setsid >/dev/null 2>&1; then
		setsid "$@" >>"$log" 2>&1 &
	else
		perl -e 'use POSIX qw(setsid); setsid(); exec @ARGV or die $!;' "$@" >>"$log" 2>&1 &
	fi
	printf '%s\n' "$!"
}

## Whether a factory's machine is running, and what is running it. The runner
## is an ordinary process on the operator's host, so this is a pid file and the
## question every other verb asks first.
cageworks_machine_pid() {
	local factory="$1" dir
	dir="$(cageworks_machine_dir "$factory")" || return 1
	[ -f "$dir/pid" ] || return 1
	cat "$dir/pid"
}

cageworks_machine_running() {
	local pid
	pid="$(cageworks_machine_pid "$1" 2>/dev/null)" || return 1
	[ -n "$pid" ] || return 1
	kill -0 "$pid" 2>/dev/null
}

## Reaching a machine cageworks built. Its own key, its own port, and a known
## hosts file of its own: a factory that changes identity is a factory to look
## at, and it must not be able to look like another one.
cageworks_machine_ssh_args() {
	local factory="$1" dir key port
	dir="$(cageworks_machine_dir "$factory")" || return 1
	key="$(cageworks_machine_key "$factory")" || return 1
	port="$(cageworks_machine_port "$factory")" || return 1
	printf '%s\n' \
		-i "$key" \
		-p "$port" \
		-o "UserKnownHostsFile=$dir/known_hosts" \
		-o "StrictHostKeyChecking=accept-new" \
		-o "IdentitiesOnly=yes" \
		-o "ConnectTimeout=5" \
		-o "BatchMode=yes"
}
