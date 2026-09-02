# shellcheck shell=bash
## Handing a role session its guidance (PRD-003).
##
## Sourced by store path into nixcage-container beside role-uid.sh. A file
## rather than an inline string so shellcheck reads it and bats can source it.

## The nspawn arguments that put the guidance inside a role's session. An
## ordinary session gets none: it is not a role, and the rules here are about
## being one.
nixcage_role_guidance_args() {
	local guidance="$1" role="${2:-}"
	[ -n "$role" ] || return 0
	nixcage_role_name_ok "$role" || return 1
	echo "--bind-ro=$guidance:/etc/nixcage/role-guidance.md"
	echo "--setenv=NIXCAGE_ROLE_GUIDANCE=/etc/nixcage/role-guidance.md"
}
