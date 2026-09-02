# shellcheck shell=bash
## Reading the factory declaration the platform module renders (PRD-003).
##
## The declaration is a directory tree rather than a parsed format: a shell
## script reads a file without a parser, and a value that is its own file
## cannot be confused with a neighbouring one. Sourced by store path into
## nixcage-container beside role-uid.sh, whose nixcage_role_name_ok it uses.

## The repository a factory works. One repository per factory, so this is a
## single value rather than a list.
nixcage_factory_repository() {
	local root="$1" factory="$2"
	nixcage_role_name_ok "$factory" || {
		echo "nixcage: invalid factory name: $factory" >&2
		return 1
	}
	local file="$root/$factory/repository"
	if [ ! -f "$file" ]; then
		echo "nixcage: no factory declared as $factory" >&2
		return 1
	fi
	cat "$file"
}

## The roles a factory declares, one per line. A factory with none is a
## declaration mistake rather than an empty factory, so it is refused here
## instead of producing a factory nothing can run in.
nixcage_factory_roles() {
	local root="$1" factory="$2"
	nixcage_role_name_ok "$factory" || return 1
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
		echo "nixcage: factory $factory declares no roles" >&2
		return 1
	fi
	printf '%s\n' "${roles[@]}"
}

## What a role's session runs. A role may declare nothing, in which case the
## session is the ordinary one and the caller decides: which coding agent a
## role runs is a property of its declaration, never of nixcage.
nixcage_factory_role_command() {
	local root="$1" factory="$2" role="$3"
	nixcage_role_name_ok "$factory" || return 1
	nixcage_role_name_ok "$role" || {
		echo "nixcage: invalid role name: $role" >&2
		return 1
	}
	local dir="$root/$factory/roles/$role"
	if [ ! -d "$dir" ]; then
		{
			echo "nixcage: factory $factory declares no role $role; it has:"
			nixcage_factory_roles "$root" "$factory" | sed 's/^/  /'
		} >&2
		return 1
	fi
	[ -f "$dir/command" ] || return 0
	cat "$dir/command"
}
