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

## A devShell name. Wider than the above because it names an attribute of
## someone else's flake and underscores are ordinary there, and checked
## separately for exactly that reason: it is the only one of these that is not
## ours to define.
cageworks_shell_name_ok() {
	[[ "${1:-}" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_-]*$ ]]
}
