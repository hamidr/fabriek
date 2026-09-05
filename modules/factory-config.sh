# shellcheck shell=bash
## Reading the factory declaration the platform module renders (PRD-003).
##
## The declaration is a directory tree rather than a parsed format: a shell
## script reads a file without a parser, and a value that is its own file
## cannot be confused with a neighbouring one. Sourced by store path into
## cageworks-container beside names.sh, whose cageworks_name_ok and
## cageworks_shell_name_ok this file relies on.

## The repository a factory works. One repository per factory, so this is a
## single value rather than a list.
cageworks_factory_repository() {
	local root="$1" factory="$2"
	cageworks_name_ok "$factory" || {
		echo "cageworks: invalid factory name: $factory" >&2
		return 1
	}
	local file="$root/$factory/repository"
	if [ ! -f "$file" ]; then
		echo "cageworks: no factory declared as $factory" >&2
		return 1
	fi
	cat "$file"
}

## The roles a factory declares, one per line. A factory with none is a
## declaration mistake rather than an empty factory, so it is refused here
## instead of producing a factory nothing can run in.
cageworks_factory_roles() {
	local root="$1" factory="$2"
	cageworks_name_ok "$factory" || return 1
	local dir="$root/$factory/roles"
	local -a roles=()
	if [ -d "$dir" ]; then
		local path
		for path in "$dir"/*; do
			[ -d "$path" ] || continue
			roles+=("$(basename "$path")")
		done
	fi
	if [ "${#roles[@]}" -eq 0 ]; then
		echo "cageworks: factory $factory declares no roles" >&2
		return 1
	fi
	printf '%s\n' "${roles[@]}"
}

## What a role's session runs, one argv word per line. A command is argv and
## never a shell line, so nothing in it is re-split or expanded on the way. A
## role may declare nothing, in which case the session is the ordinary one:
## which coding agent a role runs is a property of its declaration, never of
## cageworks.
cageworks_factory_role_command() {
	local root="$1" factory="$2" role="$3"
	cageworks_name_ok "$factory" || return 1
	cageworks_name_ok "$role" || {
		echo "cageworks: invalid role name: $role" >&2
		return 1
	}
	local dir="$root/$factory/roles/$role"
	if [ ! -d "$dir" ]; then
		{
			echo "cageworks: factory $factory declares no role $role; it has:"
			cageworks_factory_roles "$root" "$factory" | sed 's/^/  /'
		} >&2
		return 1
	fi
	[ -f "$dir/command" ] || return 0
	cat "$dir/command"
}

## The devShell a role works in, or nothing when it names none. A specialist
## is a role with its own toolchain, and the toolchain is one devShell of the
## project's own flake: the repository declares what a JVM specialist or a
## frontend specialist has to hand, and cageworks only carries the name across.
##
## Validated here rather than where it is used. The name reaches a flake
## reference, so a declaration mistake is refused before a session is built
## around it.
cageworks_factory_role_shell() {
	local root="$1" factory="$2" role="$3"
	cageworks_factory_role_command "$root" "$factory" "$role" >/dev/null || return 1
	local file="$root/$factory/roles/$role/shell"
	[ -f "$file" ] || return 0
	local want
	want="$(cat "$file")"
	if ! cageworks_shell_name_ok "$want"; then
		echo "cageworks: role $role declares an unusable devShell name: $want" >&2
		return 1
	fi
	printf '%s\n' "$want"
}

## What a role can do, one capability per line. A role that declares none can
## take no stage's work: capability is what a stage resolves through, so an
## undeclared one is a role with a cage and nothing to do (ADR-015).
cageworks_factory_role_provides() {
	local root="$1" factory="$2" role="$3"
	cageworks_factory_role_command "$root" "$factory" "$role" >/dev/null || return 1
	local file="$root/$factory/roles/$role/provides"
	[ -f "$file" ] || return 0
	cat "$file"
}

## The roles that provide a capability, in declaration order. Order is the
## whole tie-break: among idle capable roles the first one takes the task, so
## a factory replays the same way twice (ADR-015).
cageworks_factory_roles_providing() {
	local root="$1" factory="$2" capability="$3"
	[ -n "$capability" ] || return 1
	local role line
	while IFS= read -r role; do
		[ -n "$role" ] || continue
		while IFS= read -r line; do
			[ "$line" = "$capability" ] || continue
			echo "$role"
			break
		done < <(cageworks_factory_role_provides "$root" "$factory" "$role")
	done < <(cageworks_factory_roles "$root" "$factory")
}
