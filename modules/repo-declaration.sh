# shellcheck shell=bash
## The factory a repository declares about itself (ADR-020).
##
## Two things live here and they are deliberately separable. Validation is
## pure: JSON in, either the same JSON out or a message naming what was wrong,
## with no nix and no git anywhere near it. Reading is the only part that needs
## either, and it is a thin wrapper that hands what it read to the validator.
##
## The schema is closed and it is data. Every check reads the one table below,
## so a field is added by editing one line rather than by finding every place
## that lists it. What "closed" means is schema.sh's, shared with the operator's
## own declaration so the two cannot drift apart.
##
## Sourced by store path into fabriek-container beside names.sh, whose
## fabriek_name_ok and fabriek_shell_name_ok this file relies on rather
## than restating the alphabet they accept.

## The schema, and the problems a declaration has against it. One jq program
## because a declaration is one value: a check that has to see the roles and
## the stages at once cannot be a separate pass.
fabriek_declaration_program() {
	## resources is not written out here. What a factory may ask of the machine
	## is one table in resources.sh, read by this schema, by the operator's own
	## schema and by the clamp that meets one against the other.
	printf 'def schema:\n  { top:       ["name", "roles", "workflows", "resources", "decider", "catalogue"]\n'
	printf '  , decider:   ["policy"]\n'
	printf '  , role:      ["command", "provides", "shell", "specialists"]\n'
	printf '  , workflow:  ["stages", "budget", "consults"]\n'
	printf '  , stage:     ["needs", "ready", "done", "gate", "fanout", "verdict"]\n'
	printf '  , budget:    ["runs"]\n'
	printf '  , resources: %s\n  };\n' "$(fabriek_resource_field_names_json)"
	cat <<'JQ'

. as $d
| (if ($d.roles | type) == "object" then $d.roles else {} end) as $roles
| ([$roles[] | (.provides? // []) | .[]] | unique) as $provided
| ($roles | keys) as $roleNames
| [
    unknown($d; schema.top; "declaration"),

    (if ($d.name | type) == "string" and ($d.name | length) > 0
     then [] else ["declaration: no name"] end),

    (if ($d.roles | type) != "object" or ($d.roles | length) == 0
     then ["declaration: no roles are declared, so this repository declares no factory"]
     else [] end),

    ($roles | to_entries | map(
       .key as $r | .value as $v |
       [ unknown($v; schema.role; "role \($r)"),
         (if ($v | type) != "object"
          then ["role \($r): is not a declaration"] else [] end),
         (if ($v.command? // null) == null then []
          elif ($v.command | type) != "array"
          then ["role \($r): command must be argv, one word per element, never a shell line"]
          elif ($v.command | map(type != "string") | any)
          then ["role \($r): command must be argv, one word per element"]
          else [] end),
         (if ($v.provides? | type) != "array" or ($v.provides | length) == 0
          then ["role \($r): provides nothing, so no stage can ever reach it"]
          else [] end),
         (if ($v.shell? // null) == null then []
          elif ($v.shell | type) != "string"
          then ["role \($r): shell must name one devShell of this flake"]
          else [] end),
         (if ($v.specialists? // null) == null then []
          elif ($v.specialists | type) != "array"
          then ["role \($r): specialists must be a list of names from the catalogue"]
          elif ($v.specialists | map(type != "string") | any)
          then ["role \($r): specialists must be a list of names, one per element"]
          else [] end)
       ] | cat) | cat),

    ((if ($d.workflows | type) == "object" then $d.workflows else {} end)
     | to_entries | map(
       .key as $w | .value as $v |
       [ unknown($v; schema.workflow; "workflow \($w)"),
         (if ($v.stages? | type) != "array" or ($v.stages | length) == 0
          then ["workflow \($w): declares no stages"] else [] end),
         unknown(($v.budget? // {}); schema.budget; "workflow \($w) budget"),
         ((($v.stages? // []) | if type == "array" then . else [] end)
          | to_entries | map(
            .key as $i | .value as $s |
            [ unknown($s; schema.stage; "workflow \($w) stage \($i)"),
              (if ($s.needs? | type) != "string"
               then ["workflow \($w) stage \($i): needs no capability"]
               elif ($provided | index($s.needs)) == null
               then ["workflow \($w) stage \($i): needs \($s.needs), which no declared role provides"]
               else [] end),
              (if ($s.ready? // null) == null then []
               elif ($s.ready | type) != "array"
               then ["workflow \($w) stage \($i): ready must be a list of field names"]
               else [] end),
              ## A stage whose done is a verdict and not a change (ADR-051):
              ## the executor asks no commit of it.
              (if ($s.verdict? // null) == null then []
               elif ($s.verdict | type) != "boolean"
               then ["workflow \($w) stage \($i): verdict must be true or false"]
               else [] end)
            ] | cat) | cat),
         ((($v.consults? // {}) | if type == "object" then . else {} end)
          | to_entries | map(
            .key as $asker | .value as $askees |
            [ (if ($roleNames | index($asker)) == null
               then ["workflow \($w): consults is declared for \($asker), which is not a declared role"]
               else [] end),
              ((($askees // []) | if type == "array" then . else [] end)
               | map(select(. as $a | ($roleNames | index($a)) == null)
                     | "workflow \($w): consults \(.), which is not a declared role"))
            ] | cat) | cat)
       ] | cat) | cat),

    unknown(($d.resources? // {}); schema.resources; "resources"),
    unknown(($d.decider? // {}); schema.decider; "decider"),

    ## The decider's policy is a file inside the repository (ADR-034 point
    ## 5), read at build time; a path that could leave it is refused.
    ((($d.decider? // {}) | .policy?) as $p
     | if $p == null then []
       elif ($p | type) != "string" or ($p | length) == 0
       then ["decider: policy must name a file"]
       elif ($p | startswith("/")) or ($p | split("/") | index("..")) != null
       then ["decider: policy must be a path inside the repository: \($p)"]
       else [] end),

    ## A repository's own catalogue is a directory inside it (ADR-042 point
    ## 3), read at build time like the policy; a path that could leave it
    ## is refused.
    ($d.catalogue? as $c
     | if $c == null then []
       elif ($c | type) != "string" or ($c | length) == 0
       then ["catalogue: must name a directory"]
       elif ($c | startswith("/")) or ($c | split("/") | index("..")) != null
       then ["catalogue: must be a path inside the repository: \($c)"]
       else [] end),

    ((($d.resources? // {}) | if type == "object" then . else {} end)
     | [ (if ((.cores? // 1) | type) != "number"
          then ["resources: cores must be a number"] else [] end),
         (if ((.concurrency? // 1) | type) != "number"
          then ["resources: concurrency must be a number"] else [] end),
         (if ((.memory? // "1G") | type) != "string"
          then ["resources: memory must be a size"] else [] end),
         (if ((.roleQuota? // "1G") | type) != "string"
          then ["resources: roleQuota must be a size"] else [] end),
         (if ((.recordQuota? // "1G") | type) != "string"
          then ["resources: recordQuota must be a size"] else [] end),
         (if ((.tokens? // 1) | type) != "number"
          then ["resources: tokens must be a number"] else [] end),
         (if (.egress? // null) == null then []
          elif (.egress | type) != "array"
          then ["resources: egress must be a list of endpoints"]
          elif (.egress | map(type != "string") | any)
          then ["resources: egress must be a list of endpoints, one host per element"]
          else [] end)
       ] | cat)
  ] | cat | .[]
JQ
}

## Every name a declaration puts somewhere a name has to be usable, as
## "kind<TAB>where<TAB>value". Emitted rather than checked here so that the
## alphabet stays in names.sh and is not written twice.
fabriek_declaration_declared_names() {
	jq -r '
    [ "factory\tname\t\(.name // "")" ]
    + ((if (.roles | type) == "object" then .roles else {} end) | to_entries
       | map("role\trole \(.key)\t\(.key)")
       + map(select(.value.shell? != null) | "shell\trole \(.key)\t\(.value.shell)")
       + map(.key as $r | ((.value.specialists? // []) | if type == "array" then . else [] end
             | map(select(type == "string")) | map("specialist\trole \($r)\t\(.)")) | .[])
       + map(.key as $r | ((.value.provides? // []) | map("capability\trole \($r)\t\(.)")) | .[]))
    + ((if (.workflows | type) == "object" then .workflows else {} end) | to_entries
       | map("factory\tworkflow \(.key)\t\(.key)"))
    + (((.resources? // {}) | .egress? // []) | if type == "array" then . else [] end
       | map(select(type == "string")) | map("endpoint\tresources\t\(.)"))
    | .[]'
}

## The names a declaration uses, checked against the alphabet each kind of name
## has to survive. Reported alongside the schema's own problems rather than
## instead of them, so one read of a bad declaration names everything wrong
## with it.
fabriek_declaration_check_names() {
	local declaration="$1" kind where value failed=0
	while IFS=$'\t' read -r kind where value; do
		case "$kind" in
		shell)
			fabriek_shell_name_ok "$value" && continue
			echo "fabriek: $where: shell is not a devShell name: $value" >&2
			;;
		endpoint)
			fabriek_host_ok "$value" && continue
			echo "fabriek: $where: egress is not a host: $value" >&2
			;;
		role)
			if [ "$value" = "$FABRIEK_DECIDER" ]; then
				echo "fabriek: $where: $value is the machine's own role and cannot be declared" >&2
			elif fabriek_role_name_ok "$value"; then
				continue
			else
				echo "fabriek: $where: a role name is at most $FABRIEK_ROLE_NAME_MAX characters of a usable name: $value" >&2
			fi
			;;
		*)
			fabriek_name_ok "$value" && continue
			echo "fabriek: $where: $kind is not a usable name: $value" >&2
			;;
		esac
		failed=1
	done < <(printf '%s' "$declaration" | fabriek_declaration_declared_names)
	return "$failed"
}

## JSON in, the same JSON out when it is a declaration, and a message naming
## what was wrong when it is not.
fabriek_declaration_validate() {
	local declaration failed=0
	declaration="$(cat)"

	if ! printf '%s' "$declaration" | jq -e . >/dev/null 2>&1; then
		echo "fabriek: the declaration is not valid JSON" >&2
		return 1
	fi

	printf '%s' "$declaration" |
		fabriek_schema_check "$(fabriek_declaration_program)" declaration >/dev/null || failed=1
	fabriek_declaration_check_names "$declaration" || failed=1

	[ "$failed" -eq 0 ] || return 1
	printf '%s\n' "$declaration"
}

## A string, as nix will read it back. The flake reference below is built from
## a path the operator gave us, and a path is allowed to contain the three
## characters that would otherwise end the string or start an interpolation.
fabriek_nix_string() {
	local value="$1"
	value="${value//\\/\\\\}"
	value="${value//\"/\\\"}"
	value="${value//\$/\\\$}"
	printf '"%s"' "$value"
}

## The rev a declaration is read from, which is what makes which declaration a
## run used reconstructable afterwards.
fabriek_declaration_rev() {
	local repo="$1"
	git -C "$repo" rev-parse HEAD 2>/dev/null || {
		echo "fabriek: $repo has no commit to read a declaration from" >&2
		return 1
	}
}

## The declaration a repository has committed. Read from the commit and never
## from the working tree (ADR-020 point 3a): the factory working a repository
## is the one its history declares.
##
## The attribute is reached through getFlake rather than through a "#fabriek"
## fragment, because a fragment resolves packages.<system>.fabriek first and
## a repository with a package of that name would shadow its own declaration.
fabriek_declaration_read() {
	local repo="$1" rev absolute output
	if ! absolute="$(cd "$repo" 2>/dev/null && pwd)"; then
		echo "fabriek: no such repository: $repo" >&2
		return 1
	fi
	rev="$(fabriek_declaration_rev "$absolute")" || return 1
	## nix's own complaint is kept and shown. Discarding it made every
	## failure read as "no fabriek output", including the ones that were
	## nix refusing to run at all, and a message that names the wrong cause
	## costs more than the noise it saves.
	local why
	if ! output="$(nix eval --json --no-allow-import-from-derivation --expr \
		"(builtins.getFlake $(fabriek_nix_string "git+file://$absolute?rev=$rev")).fabriek" 2>/tmp/fabriek-eval.$$)"; then
		why="$(tail -3 "/tmp/fabriek-eval.$$" 2>/dev/null)"
		rm -f "/tmp/fabriek-eval.$$"
		echo "fabriek: $absolute declares no factory at $rev${why:+: $why}" >&2
		return 1
	fi
	rm -f "/tmp/fabriek-eval.$$"
	printf '%s' "$output" | fabriek_declaration_validate
}
