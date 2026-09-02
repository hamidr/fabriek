# shellcheck shell=bash
## Allocation of the uid a factory role's cage is mapped onto (ADR-010).
##
## Sourced by store path into nixcage-container, and by bats directly, which
## is why it is a file rather than an inline string.
##
## The store is one line per allocation, "<role> <uid>", where a role that has
## been forgotten keeps its line under the name "-". Nothing is ever removed,
## because a reissued uid would hand a new role the files of a dead one.

## Role names index the store, appear in paths, and are joined into container
## names, so they share the alphabet nixcage-container's own check_name
## accepts. Anything outside it is refused rather than escaped.
nixcage_role_name_ok() {
	[[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]
}

## mkdir is the portable atomic test-and-set; the guest has flock but the test
## suite runs on the developer's machine, which may not.
nixcage_role_lock() {
	local lock="$1.lock" waited=0
	while ! mkdir "$lock" 2>/dev/null; do
		waited=$((waited + 1))
		if [ "$waited" -gt 500 ]; then
			echo "nixcage: uid store is locked: $lock" >&2
			return 1
		fi
		sleep 0.01
	done
}

nixcage_role_unlock() {
	rmdir "$1.lock" 2>/dev/null || true
}

## Print the uid for <role>, allocating one on first use. Allocation is
## strictly increasing, so a forgotten role's number is never handed out again.
nixcage_role_uid() {
	local store="$1" base="$2" size="$3" role="$4"

	if ! nixcage_role_name_ok "$role"; then
		echo "nixcage: invalid role name: $role" >&2
		return 1
	fi

	nixcage_role_lock "$store" || return 1
	trap 'nixcage_role_unlock "$store"' RETURN

	[ -f "$store" ] || : >"$store"

	local existing
	existing="$(awk -v r="$role" '$1 == r { print $2; exit }' "$store")"
	if [ -n "$existing" ]; then
		echo "$existing"
		return 0
	fi

	local highest next
	highest="$(awk 'BEGIN { h = -1 } $2 > h { h = $2 } END { print h }' "$store")"
	if [ "$highest" -lt "$base" ]; then
		next="$base"
	else
		next=$((highest + 1))
	fi

	if [ "$next" -ge $((base + size)) ]; then
		echo "nixcage: uid range $base+$size is exhausted; widen nixcage.supervisor.roleUidRange" >&2
		return 1
	fi

	printf '%s %s\n' "$role" "$next" >>"$store"
	echo "$next"
}

## Forget a role without freeing its number: the line stays so the uid stays
## claimed, and the files it owns can still be traced to something.
nixcage_role_forget() {
	local store="$1" role="$2"

	nixcage_role_name_ok "$role" || return 1
	[ -f "$store" ] || return 0

	nixcage_role_lock "$store" || return 1
	trap 'nixcage_role_unlock "$store"' RETURN

	local tmp="$store.tmp.$$"
	awk -v r="$role" '{ if ($1 == r) print "- " $2; else print }' "$store" >"$tmp"
	mv "$tmp" "$store"
}

## The login uid 0 carries inside a cage. An ordinary project session stays
## root; a role session is named after the role, so the prompt, the process
## table, and anything resolving the uid say which role is running.
nixcage_role_login() {
	if [ -z "${1:-}" ]; then
		echo root
	else
		nixcage_role_name_ok "$1" || return 1
		echo "$1"
	fi
}

## The container's /etc/passwd. Rendered here rather than inline so the name
## that reaches it is the validated one.
nixcage_role_passwd() {
	local login
	login="$(nixcage_role_login "${1:-}")" || return 1
	printf '%s:x:0:0:%s:/root:/bin/sh\n' "$login" "$login"
	printf 'nobody:x:65534:65534:nobody:/var/empty:/bin/sh\n'
}
