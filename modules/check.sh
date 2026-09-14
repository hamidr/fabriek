# shellcheck shell=bash
## fabriek check <repo>: what fabriek up would refuse, said here first.
##
## The declaration is read at the commit, as up reads it (ADR-020), and
## validated by the same schema; then every specialist a role names is
## resolved against the shipped catalogue and the repository's own, at that
## same commit, by composing each role exactly as the machine build does
## (ADR-042). Evaluation only: nothing is built, and a name no catalogue has
## is one plain line rather than a trace minutes into a build.
##
## Sourced by store path into fabriek beside repo-declaration.sh, whose
## reader and validator this uses.

## The composition of every role, as JSON {role: [names]}, or nix's own
## error with the thrown line brought to the front.
fabriek_check_compose() {
	local self="$1" repo="$2" rev="$3" system="$4" out err
	err="$(mktemp)"
	if out="$(nix eval --json --impure --expr "
	  let flake = builtins.getFlake $(fabriek_nix_string "path:$self");
	      pkgs = flake.inputs.nixpkgs.legacyPackages.$system;
	      project = builtins.getFlake $(fabriek_nix_string "git+file://$repo?rev=$rev");
	      decl = project.fabriek;
	      cat = flake.lib.catalogue {
	        inherit pkgs;
	        extra = if decl ? catalogue then [ \"\${project}/\${decl.catalogue}\" ] else [ ];
	      };
	  in builtins.mapAttrs (name: role:
	       (cat.compose { role = name; specialists = role.specialists or [ ]; }).order) decl.roles
	" 2>"$err")"; then
		rm -f "$err"
		printf '%s\n' "$out"
		return 0
	fi
	## The thrown message is the last "error:" line of the trace and the
	## one a person can act on; the trace follows for whoever wants it.
	grep -E '^\s*error: ' "$err" | tail -1 | sed 's/^[[:space:]]*error: //' >&2
	rm -f "$err"
	return 1
}

## fabriek_check_repo <self> <repo> <system>
fabriek_check_repo() {
	local self="$1" repo="$2" system="$3" rev declaration composed
	local absolute
	absolute="$(cd "$repo" 2>/dev/null && pwd)" || {
		echo "fabriek: no such repository: $repo" >&2
		return 1
	}
	rev="$(fabriek_declaration_rev "$absolute")" || return 1
	declaration="$(fabriek_declaration_read "$absolute")" || return 1
	local name
	name="$(printf '%s' "$declaration" | jq -r .name)"
	echo "checked $name at $(git -C "$absolute" rev-parse --short "$rev")"
	if [ -n "$(git -C "$absolute" status --porcelain 2>/dev/null)" ]; then
		echo "note: the working tree differs from that commit; fabriek up reads the commit"
	fi
	composed="$(fabriek_check_compose "$self" "$absolute" "$rev" "$system")" || return 1
	printf '%s' "$composed" | jq -r 'to_entries[] | "  \(.key): \(if .value == [] then "(no specialists)" else (.value | join(", ")) end)"'
}
