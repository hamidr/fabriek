# shellcheck shell=bash
## The factory a repository declares about itself (ADR-020).
##
## Two things live here and they are deliberately separable. Validation is
## pure: JSON in, either the same JSON out or a message naming what was wrong,
## with no nix and no git anywhere near it. Reading is the only part that
## needs either, and it is a thin wrapper that hands what it read to the
## validator.
##
## The schema is closed and it is data. Every check reads the one table in
## cageworks_declaration_schema, so a field is added by editing one line rather
## than by finding every place that lists it. A key nobody recognises is
## refused with its own name rather than ignored, which is the whole of what
## stops a repository reaching the machine it is given.
##
## Sourced by store path into cageworks-container beside names.sh, whose
## cageworks_name_ok and cageworks_shell_name_ok this file relies on rather
## than restating the alphabet they accept.

## Everything the schema allows, at every level. jq reads this and nothing else
## decides what a declaration may say.
cageworks_declaration_schema() {
	cat <<'JQ'
def schema:
  { top:       ["name", "roles", "workflows", "resources"]
  , role:      ["command", "provides", "shell"]
  , workflow:  ["stages", "budget", "consults"]
  , stage:     ["needs", "ready", "done", "gate"]
  , budget:    ["runs"]
  , resources: ["memory", "cores", "roleQuota", "concurrency"]
  };
JQ
}

## The problems in a declaration, one sentence per line, empty when there are
## none. Written as one jq program because a declaration is one value: a check
## that has to see the roles and the stages at once cannot be a separate pass.
cageworks_declaration_problems() {
	local program
	program="$(cageworks_declaration_schema)
$(
		cat <<'JQ'
# Every level is checked by this one function, which is why adding a level
# costs a line in schema and a call here rather than a new kind of check.
def unknown($obj; $allowed; $where):
  if ($obj | type) == "object"
  then (($obj | keys_unsorted) - $allowed) | map("\($where): unknown key \(.)")
  else [] end;

def cat: reduce .[] as $each ([]; . + $each);

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

    ((($d.resources? // {}) | if type == "object" then . else {} end)
     | [ (if ((.cores? // 1) | type) != "number"
          then ["resources: cores must be a number"] else [] end),
         (if ((.concurrency? // 1) | type) != "number"
          then ["resources: concurrency must be a number"] else [] end),
         (if ((.memory? // "1G") | type) != "string"
          then ["resources: memory must be a size"] else [] end),
         (if ((.roleQuota? // "1G") | type) != "string"
          then ["resources: roleQuota must be a size"] else [] end)
       ] | cat)
  ] | cat | .[]
JQ
	)"
	jq -r "$program"
}

## Every name a declaration puts somewhere a name has to be usable, as
## "kind<TAB>where<TAB>value". Emitted rather than checked here so that the
## alphabet stays in names.sh and is not written twice.
cageworks_declaration_declared_names() {
	jq -r '
    [ "factory\tname\t\(.name // "")" ]
    + ((if (.roles | type) == "object" then .roles else {} end) | to_entries
       | map("role\trole \(.key)\t\(.key)")
       + map(select(.value.shell? != null) | "shell\trole \(.key)\t\(.value.shell)")
       + map(.key as $r | ((.value.provides? // []) | map("capability\trole \($r)\t\(.)")) | .[]))
    + ((if (.workflows | type) == "object" then .workflows else {} end) | to_entries
       | map("factory\tworkflow \(.key)\t\(.key)"))
    | .[]'
}

## JSON in, the same JSON out when it is a declaration, and a message naming
## what was wrong when it is not.
cageworks_declaration_validate() {
	local declaration problems failed=0
	declaration="$(cat)"

	if ! printf '%s' "$declaration" | jq -e . >/dev/null 2>&1; then
		echo "cageworks: the declaration is not valid JSON" >&2
		return 1
	fi

	problems="$(printf '%s' "$declaration" | cageworks_declaration_problems)" || return 1
	if [ -n "$problems" ]; then
		while IFS= read -r problem; do
			echo "cageworks: $problem" >&2
		done <<<"$problems"
		failed=1
	fi

	local kind where value
	while IFS=$'\t' read -r kind where value; do
		case "$kind" in
		shell)
			cageworks_shell_name_ok "$value" && continue
			echo "cageworks: $where: shell is not a devShell name: $value" >&2
			;;
		*)
			cageworks_name_ok "$value" && continue
			echo "cageworks: $where: $kind is not a usable name: $value" >&2
			;;
		esac
		failed=1
	done < <(printf '%s' "$declaration" | cageworks_declaration_declared_names)

	[ "$failed" -eq 0 ] || return 1
	printf '%s\n' "$declaration"
}

## A string, as nix will read it back. The flake reference below is built from
## a path the operator gave us, and a path is allowed to contain the three
## characters that would otherwise end the string or start an interpolation.
cageworks_nix_string() {
	local value="$1"
	value="${value//\\/\\\\}"
	value="${value//\"/\\\"}"
	value="${value//\$/\\\$}"
	printf '"%s"' "$value"
}

## The declaration a repository has committed. Read from the commit and never
## from the working tree (ADR-020 point 3a): the factory working a repository
## is the one its history declares, and the rev read is a fact worth recording
## beside the work.
##
## The attribute is reached through getFlake rather than through a "#cageworks"
## fragment, because a fragment resolves packages.<system>.cageworks first and
## a repository with a package of that name would shadow its own declaration.
cageworks_declaration_read() {
	local repo="$1" rev absolute output
	if ! absolute="$(cd "$repo" 2>/dev/null && pwd)"; then
		echo "cageworks: no such repository: $repo" >&2
		return 1
	fi
	if ! rev="$(git -C "$absolute" rev-parse HEAD 2>/dev/null)"; then
		echo "cageworks: $absolute has no commit to read a declaration from" >&2
		return 1
	fi
	if ! output="$(nix eval --json --no-allow-import-from-derivation --expr \
		"(builtins.getFlake $(cageworks_nix_string "git+file://$absolute?rev=$rev")).cageworks" 2>/dev/null)"; then
		echo "cageworks: $absolute declares no factory: its flake has no cageworks output at $rev" >&2
		return 1
	fi
	printf '%s' "$output" | cageworks_declaration_validate
}

## The rev a declaration was read from, which is what makes which declaration a
## run used reconstructable afterwards.
cageworks_declaration_rev() {
	local repo="$1"
	git -C "$repo" rev-parse HEAD 2>/dev/null || {
		echo "cageworks: $repo has no commit to read a declaration from" >&2
		return 1
	}
}
