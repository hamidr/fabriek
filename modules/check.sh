# shellcheck shell=bash
## The catalogue asked on the operator's host: fabriek check, catalogue list
## and show, role show. Evaluation only, nothing built (ADR-042).
##
## The declaration is read at the commit, as up reads it (ADR-020), and
## validated by the same schema; a repository's own catalogue is read at the
## same commit; every role is composed exactly as the machine build does. A
## name no catalogue has is one plain line rather than a trace minutes into
## a build.
##
## Sourced by store path into fabriek beside repo-declaration.sh, whose
## reader and validator this uses. With FABRIEK_JSON set, each verb prints
## the structure its text is made from and nothing else (ADR-047).

## A Nix expression over `cat`, the catalogues of fabriek and of the
## repository at its commit when one is given, evaluated as JSON. On
## failure the thrown message, the last "error:" line of the trace, is what
## a person sees, because it is the one line they can act on.
##
## fabriek_catalogue_eval <self> <system> <repo-or-empty> <rev-or-empty> <expr>
fabriek_catalogue_eval() {
	local self="$1" system="$2" repo="$3" rev="$4" expr="$5" out err project extra
	if [ -n "$repo" ]; then
		project="builtins.getFlake $(fabriek_nix_string "git+file://$repo?rev=$rev")"
		extra="if project.fabriek ? catalogue then [ \"\${project}/\${project.fabriek.catalogue}\" ] else [ ]"
	else
		project="{ fabriek = { }; }"
		extra="[ ]"
	fi
	err="$(mktemp)"
	if out="$(nix eval --json --impure --expr "
	  let flake = builtins.getFlake $(fabriek_nix_string "path:$self");
	      pkgs = flake.inputs.nixpkgs.legacyPackages.$system;
	      project = $project;
	      decl = project.fabriek;
	      cat = flake.lib.catalogue { inherit pkgs; extra = $extra; };
	      show = c: {
	        inherit (c) order servers promptText;
	        tools = map (t: t.pname or t.name) c.tools;
	        skills = map (s: { inherit (s) name description; }) c.skillsDescribed;
	        tests = builtins.fromJSON (builtins.unsafeDiscardStringContext c.testsJson);
	      };
	  in $expr
	" 2>"$err")"; then
		rm -f "$err"
		printf '%s\n' "$out"
		return 0
	fi
	grep -E '^\s*error: ' "$err" | tail -1 | sed 's/^[[:space:]]*error: //' >&2
	rm -f "$err"
	return 1
}

## The repository's commit and its validated declaration, or a refusal.
## Sets FABRIEK_CHECK_REV and FABRIEK_CHECK_DECLARATION.
fabriek_check_read() {
	local repo="$1" absolute
	absolute="$(cd "$repo" 2>/dev/null && pwd)" || {
		echo "fabriek: no such repository: $repo" >&2
		return 1
	}
	FABRIEK_CHECK_REPO="$absolute"
	FABRIEK_CHECK_REV="$(fabriek_declaration_rev "$absolute")" || return 1
	FABRIEK_CHECK_DECLARATION="$(fabriek_declaration_read "$absolute")" || return 1
}

## fabriek_check_repo <self> <repo> <system>
fabriek_check_repo() {
	local self="$1" repo="$2" system="$3" composed name
	fabriek_check_read "$repo" || return 1
	name="$(printf '%s' "$FABRIEK_CHECK_DECLARATION" | jq -r .name)"
	if [ -z "${FABRIEK_JSON:-}" ]; then
		echo "checked $name at $(git -C "$FABRIEK_CHECK_REPO" rev-parse --short "$FABRIEK_CHECK_REV")"
		if [ -n "$(git -C "$FABRIEK_CHECK_REPO" status --porcelain 2>/dev/null)" ]; then
			echo "note: the working tree differs from that commit; fabriek up reads the commit"
		fi
	fi
	composed="$(fabriek_catalogue_eval "$self" "$system" "$FABRIEK_CHECK_REPO" "$FABRIEK_CHECK_REV" \
		'builtins.mapAttrs (name: role: (cat.compose { role = name; specialists = role.specialists or [ ]; }).order) decl.roles')" || return 1
	if [ -n "${FABRIEK_JSON:-}" ]; then
		printf '%s' "$composed" | jq -c --arg name "$name" --arg rev "$FABRIEK_CHECK_REV" '{factory: $name, rev: $rev, roles: .}'
		return 0
	fi
	printf '%s' "$composed" | jq -r 'to_entries[] | "  \(.key): \(if .value == [] then "(no specialists)" else (.value | join(", ")) end)"'
}

## One composed role or specialist, as a person reads it, or as it is.
fabriek_catalogue_print() {
	if [ -n "${FABRIEK_JSON:-}" ]; then
		jq -c .
		return 0
	fi
	jq -r '
	  "order: \(.order | join(", "))",
	  "tools: \(.tools | unique | join(", "))",
	  "skills:",
	  (.skills[] | "  \(.name): \(.description)"),
	  "servers: \(.servers | join(", "))",
	  "tests: \(.tests.files | join(", "))",
	  "",
	  .promptText'
}

## fabriek_catalogue_list <self> <system> [<repo>]
fabriek_catalogue_list() {
	local self="$1" system="$2" repo="${3:-}" rev="" listed
	if [ -n "$repo" ]; then
		fabriek_check_read "$repo" || return 1
		repo="$FABRIEK_CHECK_REPO"
		rev="$FABRIEK_CHECK_REV"
	fi
	listed="$(fabriek_catalogue_eval "$self" "$system" "$repo" "$rev" \
		'{ specialists = builtins.mapAttrs (_: s: map (p: p.name) (s.extends or [ ])) cat.specialists;
		   skills = builtins.mapAttrs (_: s: s.description) cat.skillsDescribed; }')" || return 1
	if [ -n "${FABRIEK_JSON:-}" ]; then
		printf '%s' "$listed" | jq -c .
		return 0
	fi
	printf '%s' "$listed" | jq -r '
	  "specialists:",
	  (.specialists | to_entries[] | "  \(.key): \(if .value == [] then "extends nothing" else "extends " + (.value | join(", ")) end)"),
	  "skills:",
	  (.skills | to_entries[] | "  \(.key): \(.value)")'
}

## fabriek_catalogue_show <self> <system> <name> [<repo>]
fabriek_catalogue_show() {
	local self="$1" system="$2" name="$3" repo="${4:-}" rev="" shown
	fabriek_name_ok "$name" || {
		echo "fabriek: not a specialist name: $name" >&2
		return 1
	}
	if [ -n "$repo" ]; then
		fabriek_check_read "$repo" || return 1
		repo="$FABRIEK_CHECK_REPO"
		rev="$FABRIEK_CHECK_REV"
	fi
	shown="$(fabriek_catalogue_eval "$self" "$system" "$repo" "$rev" \
		"show (cat.compose { role = \"$name\"; specialists = [ \"$name\" ]; })")" || return 1
	printf '%s' "$shown" | fabriek_catalogue_print
}

## fabriek_role_show <self> <system> <repo> <role>
fabriek_role_show() {
	local self="$1" system="$2" repo="$3" role="$4" shown
	fabriek_role_name_ok "$role" || {
		echo "fabriek: invalid role name: $role" >&2
		return 1
	}
	fabriek_check_read "$repo" || return 1
	shown="$(fabriek_catalogue_eval "$self" "$system" "$FABRIEK_CHECK_REPO" "$FABRIEK_CHECK_REV" \
		"show (cat.compose { role = \"$role\"; specialists = decl.roles.\"$role\".specialists or [ ]; })")" || return 1
	printf '%s' "$shown" | fabriek_catalogue_print
}
