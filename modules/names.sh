# shellcheck shell=bash
## The names fabriek accepts, checked where they are declared.
##
## A factory, a role, a capability and a devShell all arrive from a
## declaration and end up in a path, a git ref, a container name or a flake
## reference. Refusing an unusable one where it is read is the whole reason
## nothing downstream has to escape it.
##
## These used to come from nixcage, which validated the same names because the
## factory lived inside it. They are ours now: what a role is called is a fact
## about fabriek, and nixcage checks only the names that reach its own
## mechanics (ADR-018).
##
## Sourced by store path into fabriek-container, and by bats directly, which
## is why it is a file rather than an inline string.

## Factory, role and capability names. They index directories, are joined into
## container names, and become the first segment of a git ref, so they share
## the alphabet a container name accepts. Anything outside it is refused rather
## than escaped.
fabriek_name_ok() {
	[[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]
}

## A role's cage is named <factory>-<role> (ADR-067 point 3), a machine
## name to nspawn, which takes sixty-four characters; the cage's veth
## carries a hash of the name (nixcage ADR-013), so no interface name bounds
## it. The role alone is checked where only the role is known, the sum
## where the declaration names both.
FABRIEK_ROLE_NAME_MAX=64
fabriek_role_name_ok() {
	fabriek_name_ok "$1" && [ "${#1}" -le "$FABRIEK_ROLE_NAME_MAX" ]
}
fabriek_cage_name_ok() {
	local factory="$1" role="$2"
	[ $((${#factory} + 1 + ${#role})) -le "$FABRIEK_ROLE_NAME_MAX" ]
}

## The branch a factory integrates into and shares with the operator, whose
## name lands beside the roles' under fabriek/<factory>/ in the checkout
## (ADR-067 point 5), so no role may take it. Named once; factory-clone.sh
## reads it from here.
fabriek_factory_shared_branch_name() {
	echo "main"
}

## A devShell name. Wider than the above because it names an attribute of
## someone else's flake and underscores are ordinary there, and checked
## separately for exactly that reason: it is the only one of these that is not
## ours to define.
fabriek_shell_name_ok() {
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
fabriek_host_ok() {
	local host="${1:-}"
	[ "${#host}" -le 253 ] || return 1
	[[ "$host" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]
}

## A header name, which reaches a line of the proxy's configuration (ADR-025).
## The HTTP token alphabet, narrowed to what a header is actually called: a
## value carrying a newline, a colon or a space would be a directive rather
## than a header, and would be one the operator did not write.
fabriek_header_name_ok() {
	[[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]]
}

## The subject a role session runs as inside its cage (ADR-028).
##

## The one role the machine provides rather than the repository declares
## (ADR-034 point 1). Its cage, its bus user and its forge account all carry
## this name, so a repository declaring a role of the same name would collide
## with it; the declaration's validation refuses that.
# shellcheck disable=SC2034  # read by the machine program and its modules
FABRIEK_DECIDER=decider
