# shellcheck shell=bash
## The ledger a role writes and cannot edit (ADR-027).
##
## Sourced by store path into cageworks-container beside names.sh. A file
## rather than an inline string so shellcheck reads it and bats can source it.
##
## journald is the writer because it stamps the identity: it reads SO_PEERCRED
## off its own socket and records _UID and _PID itself, so a role can write a
## line that lies about what it did but not one that lies about who it is.
## Nothing here writes a plain file under a role's uid, which would be a record
## a role could edit.

## Where journald listens on the machine, for the default namespace and for a
## namespaced instance. Read off systemd-journald@.socket, which is
## ListenDatagram=/run/systemd/journal.%i/socket with PassCredentials=yes.
cageworks_journal_socket_in_cage=/run/systemd/journal/socket

## The namespace a factory's journal lives in. One per factory, because
## eviction is a shared resource: a single journal for the machine would let a
## role that floods it evict every other role's entries under SystemMaxUse,
## which would make suppressing evidence a matter of writing enough of it
## (ADR-027 point 6).
##
## The name is checked here because it becomes a path and a unit instance, and
## refusing it where it is read is what stops anything downstream escaping it.
cageworks_journal_namespace() {
	local factory="$1"
	cageworks_name_ok "$factory" || {
		echo "cageworks: invalid factory name: $factory" >&2
		return 1
	}
	printf '%s\n' "$factory"
}

## The socket that namespace listens on, on the machine.
cageworks_journal_socket() {
	local ns
	ns="$(cageworks_journal_namespace "$1")" || return 1
	printf '/run/systemd/journal.%s/socket\n' "$ns"
}

## The options that put that socket inside a role's session, one argv word per
## line so nothing in them is ever re-split.
##
## A cage is systemd-nspawn with a /run of its own, so the socket is not there
## until it is asked for, and it has to arrive under the name journald's own
## client code opens rather than the namespaced one it has outside. Writable,
## because connecting to a unix socket needs write permission on it and a
## read-only bind would leave a ledger that fails as though it were missing.
cageworks_journal_args() {
	local socket
	socket="$(cageworks_journal_socket "$1")" || return 1
	echo "--bind"
	echo "$socket:$cageworks_journal_socket_in_cage"
}
