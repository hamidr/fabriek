# shellcheck shell=bash
## The bus's users, prepared and prepared again (ADR-033 point 3).
##
## A password per user under the state directory, made once and readable by
## root alone; the machine's ACL unit reads them at boot, and is restarted
## after they change so a new role's user appears without a reboot. The
## users are the declaration's roles plus the three the machine provides.
##
## Sourced by store path into cageworks-container beside names.sh.

cageworks_bus_dir() { printf '%s/bus\n' "$1"; }

## Every user the bus has, given the declaration file.
cageworks_bus_users() {
	local declaration="$1"
	jq -r '.roles | keys[]' "$declaration"
	printf '%s\n' decider executor probes
}

## A password, once.
cageworks_bus_ensure_password() {
	local state="$1" user="$2" file
	cageworks_name_ok "$user" || return 1
	file="$(cageworks_bus_dir "$state")/$user"
	[ -s "$file" ] && return 0
	mkdir -p "$(dirname "$file")"
	chmod 0700 "$(dirname "$file")"
	(umask 077 && cageworks_secret >"$file.new") && mv "$file.new" "$file"
	chmod 0400 "$file"
}
