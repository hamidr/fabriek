# shellcheck shell=bash
## Where a factory's machine lives on the operator's host (ADR-019).
##
## fabriek builds and runs one VM per factory, so it owns the way into each:
## a keypair and a forwarded port made here and kept beside that factory's disk.
## No factory reads another factory's way in, which is a property of these
## directories being separate rather than of anything being careful.
##
## This is the bookkeeping half of a machine, and it is deliberately the half
## that needs no hypervisor to be true: where the disk is, what the key is, what
## port it answers on, and which machines this host has. Building and booting
## one is elsewhere and depends on all of this.

## Where every machine on this host lives. FABRIEK_MACHINES overrides it,
## which is what the suite uses and what an operator running two sets of them
## needs. A hand reading the file a NixOS host rendered is on the host's
## state, where the host's units keep their machines (ADR-048 point 3):
## the unit and the hand are one program on one state, or ps shows nothing
## the unit started. A person's own config is a person's own state. The
## host's path is a variable for the same reason FABRIEK_HOST_CONFIG is.
## Sourced after operator-config.sh, which says which file was read.
FABRIEK_HOST_MACHINES="${FABRIEK_HOST_MACHINES:-/var/lib/fabriek/machines}"
fabriek_machine_root() {
	if [ -n "${FABRIEK_MACHINES:-}" ]; then
		printf '%s\n' "$FABRIEK_MACHINES"
		return 0
	fi
	if [ "$(fabriek_operator_config_path)" = "$FABRIEK_HOST_CONFIG" ]; then
		printf '%s\n' "$FABRIEK_HOST_MACHINES"
		return 0
	fi
	printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/fabriek/machines"
}

## One factory's machine. The name is checked here because it becomes a path,
## and refusing it where it is read is what stops anything downstream escaping
## it.
fabriek_machine_dir() {
	local factory="$1"
	fabriek_name_ok "$factory" || {
		echo "fabriek: invalid factory name: $factory" >&2
		return 1
	}
	printf '%s/%s\n' "$(fabriek_machine_root)" "$factory"
}

## A port nothing else on this host was given. Chosen once and kept, because a
## machine that answers somewhere new every time it is prepared is one nothing
## can hold a connection to.
fabriek_machine_allocate_port() {
	local taken port dir
	taken=" $(fabriek_machine_list | while IFS= read -r factory; do
		dir="$(fabriek_machine_dir "$factory")" || continue
		[ -f "$dir/port" ] && cat "$dir/port"
	done | tr '\n' ' ')"

	for port in $(seq 22100 22999); do
		case "$taken" in
		*" $port "*) continue ;;
		esac
		printf '%s\n' "$port"
		return 0
	done
	echo "fabriek: no free port left for a machine on this host" >&2
	return 1
}

## Make a factory's machine ready to be built and booted: its place, its key
## and its port. Idempotent, and it touches nothing it did not create, because
## the disk beside these outlives every transition but the one that removes it
## (ADR-019 point 3).
fabriek_machine_ensure() {
	local factory="$1" dir port
	dir="$(fabriek_machine_dir "$factory")" || return 1
	mkdir -p "$dir"

	if [ ! -f "$dir/id_ed25519" ]; then
		ssh-keygen -q -t ed25519 -N "" -C "fabriek-$factory" -f "$dir/id_ed25519" ||
			return 1
		chmod 600 "$dir/id_ed25519"
	fi

	if [ ! -f "$dir/port" ]; then
		port="$(fabriek_machine_allocate_port)" || return 1
		printf '%s\n' "$port" >"$dir/port.new"
		mv "$dir/port.new" "$dir/port"
	fi

	printf '%s\n' "$dir"
}

## What port a factory's machine answers on.
fabriek_machine_port() {
	local factory="$1" dir
	dir="$(fabriek_machine_dir "$factory")" || return 1
	if [ ! -f "$dir/port" ]; then
		echo "fabriek: $factory has no machine prepared here" >&2
		return 1
	fi
	cat "$dir/port"
}

## The private key that reaches a factory's machine, and nothing else's.
fabriek_machine_key() {
	local factory="$1" dir
	dir="$(fabriek_machine_dir "$factory")" || return 1
	if [ ! -f "$dir/id_ed25519" ]; then
		echo "fabriek: $factory has no machine prepared here" >&2
		return 1
	fi
	printf '%s\n' "$dir/id_ed25519"
}

## The machines on this host, one per line, in a stable order. A host with none
## has none, which is not an error: it is what a host looks like before the
## first factory is started.
fabriek_machine_list() {
	local root path
	root="$(fabriek_machine_root)"
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
fabriek_machine_spawn() {
	local log="$1"
	shift
	if command -v setsid >/dev/null 2>&1; then
		setsid "$@" >>"$log" 2>&1 &
		printf '%s\n' "$!"
		return 0
	fi
	## perl forks first so that whatever calls setsid is never a process group
	## leader, which is the one case setsid refuses. Backgrounding the perl
	## itself is not enough: depending on how the caller was started it may
	## already lead a group, and then the call silently does nothing.
	##
	## The parent prints the pid it made and exits; the child reopens its own
	## output on the log, so what the caller reads is the pid and nothing else.
	FABRIEK_SPAWN_LOG="$log" perl -e '
		use POSIX qw(setsid);
		my $pid = fork();
		die "fork: $!" unless defined $pid;
		if ($pid) { print "$pid\n"; exit 0; }
		setsid() or exit 1;
		open(STDIN, "<", "/dev/null") or exit 1;
		open(STDOUT, ">>", $ENV{FABRIEK_SPAWN_LOG}) or exit 1;
		open(STDERR, ">&", \*STDOUT) or exit 1;
		exec @ARGV or exit 1;
	' "$@"
}

## Whether a factory's machine is running, and what is running it. The runner
## is an ordinary process on the operator's host, so this is a pid file and the
## question every other verb asks first.
fabriek_machine_pid() {
	local factory="$1" dir
	dir="$(fabriek_machine_dir "$factory")" || return 1
	[ -f "$dir/pid" ] || return 1
	cat "$dir/pid"
}

## Asked of the process table and not with a signal: on a NixOS host the
## machine is the unit's, root's, and a hand is not root (ADR-048).
fabriek_machine_running() {
	local pid
	pid="$(fabriek_machine_pid "$1" 2>/dev/null)" || return 1
	[ -n "$pid" ] || return 1
	ps -p "$pid" >/dev/null 2>&1
}

## Reaching a machine fabriek built. Its own key, its own port, and a known
## hosts file of its own: a factory that changes identity is a factory to look
## at, and it must not be able to look like another one.
##
## A hand that cannot read the machine's key, a person beside the unit on
## a NixOS host (ADR-063 point 3), reaches with their own keys and agent,
## and keeps the machine's host key under their own state: the unit's
## file is root's too.
fabriek_machine_ssh_args() {
	local factory="$1" dir key port
	dir="$(fabriek_machine_dir "$factory")" || return 1
	key="$(fabriek_machine_key "$factory")" || return 1
	port="$(fabriek_machine_port "$factory")" || return 1
	if [ -r "$key" ]; then
		printf '%s\n' \
			-i "$key" \
			-o "UserKnownHostsFile=$dir/known_hosts" \
			-o "IdentitiesOnly=yes"
	else
		local own="${XDG_STATE_HOME:-$HOME/.local/state}/fabriek/known_hosts"
		mkdir -p "$own"
		printf '%s\n' -o "UserKnownHostsFile=$own/$factory"
	fi
	printf '%s\n' \
		-p "$port" \
		-o "StrictHostKeyChecking=accept-new" \
		-o "ConnectTimeout=5" \
		-o "BatchMode=yes"
}
