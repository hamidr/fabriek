# shellcheck shell=bash
## The names cageworks accepts, checked where they are declared.
##
## A factory, a role, a capability and a devShell all arrive from a
## declaration and end up in a path, a git ref, a container name or a flake
## reference. Refusing an unusable one where it is read is the whole reason
## nothing downstream has to escape it.
##
## These used to come from nixcage, which validated the same names because the
## factory lived inside it. They are ours now: what a role is called is a fact
## about cageworks, and nixcage checks only the names that reach its own
## mechanics (ADR-018).
##
## Sourced by store path into cageworks-container, and by bats directly, which
## is why it is a file rather than an inline string.

## Factory, role and capability names. They index directories, are joined into
## container names, and become the first segment of a git ref, so they share
## the alphabet a container name accepts. Anything outside it is refused rather
## than escaped.
cageworks_name_ok() {
	[[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]
}

## A role's name is also its cage's name, and nspawn names the cage's veth
## "ve-<cage>" within the fifteen characters the kernel gives an interface
## (ADR-037). Twelve is what is left, and a longer name would be silently
## shortened into one the bridge's rules could not match.
CAGEWORKS_ROLE_NAME_MAX=12
cageworks_role_name_ok() {
	cageworks_name_ok "$1" && [ "${#1}" -le "$CAGEWORKS_ROLE_NAME_MAX" ]
}

## A devShell name. Wider than the above because it names an attribute of
## someone else's flake and underscores are ordinary there, and checked
## separately for exactly that reason: it is the only one of these that is not
## ours to define.
cageworks_shell_name_ok() {
	[[ "${1:-}" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_-]*$ ]]
}

## An endpoint a factory may reach (ADR-025). Narrower than either of the
## above rather than wider: it becomes a line in a firewall rule and an entry
## in a proxy's allowlist, and both read a host and nothing else. A scheme, a
## path, a port or a space would each make a rule that means something other
## than what was declared, so all four are refused here rather than stripped.
##
## Labels are the DNS alphabet, a label neither opens nor closes with a dash,
## and the whole name stays inside the 253 characters a resolver will carry.
cageworks_host_ok() {
	local host="${1:-}"
	[ "${#host}" -le 253 ] || return 1
	[[ "$host" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]
}

## A header name, which reaches a line of the proxy's configuration (ADR-025).
## The HTTP token alphabet, narrowed to what a header is actually called: a
## value carrying a newline, a colon or a space would be a directive rather
## than a header, and would be one the operator did not write.
cageworks_header_name_ok() {
	[[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]]
}

## The subject a role session runs as inside its cage (ADR-028).
##
