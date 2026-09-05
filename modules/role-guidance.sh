# shellcheck shell=bash
## Handing a role session its guidance (PRD-003).
##
## Sourced by store path into cageworks-container beside names.sh. A file
## rather than an inline string so shellcheck reads it and bats can source it.

## The options that put the guidance inside a role's session, one argv word
## per line so nothing in them is ever re-split. An ordinary project session
## gets none: it is not a role, and the rules here are about being one.
##
## Read-only, and not under /etc/nixcage: nixcage refuses a bind over its own
## configuration, and a caller that could replace it would be choosing what
## every later session runs (ADR-018).
cageworks_role_guidance_args() {
	local guidance="$1" role="${2:-}"
	[ -n "$role" ] || return 0
	cageworks_name_ok "$role" || return 1
	local dst=/etc/cageworks/role-guidance.md
	echo "--bind-ro"
	echo "$guidance:$dst"
	echo "--setenv"
	echo "CAGEWORKS_ROLE_GUIDANCE=$dst"
}
