# shellcheck shell=bash
## The one file the operator owns (ADR-020 point 4).
##
## What a factory may cost on this machine, and which factories live here. The
## same file on Linux and on macOS, with no NixOS module to import, no flake to
## scaffold and no rebuild to run: reaching fabriek for the first time is
## running it, not configuring a machine.
##
## It is TOML because a person edits it, and nix parses it because nix is
## already in the path that reads a declaration and a second parser would be a
## second dependency for one file. The file's content reaches nix through the
## environment rather than through the expression, so what is read as TOML can
## never be read as Nix: a config full of interpolations is a TOML syntax
## error, which is a test below.
##
## Closed for the same reason the repository's declaration is. A ceiling that
## is ignored because it was misspelled is a ceiling nobody has.

## Where the operator's config lives. FABRIEK_CONFIG overrides it, which is
## what the suite uses and what an operator with more than one of them needs;
## then the person's own file; then the host's, which a NixOS module renders
## (ADR-048). The host's path is a variable so the suite can point it at a
## file of its own.
FABRIEK_HOST_CONFIG="${FABRIEK_HOST_CONFIG:-/etc/fabriek/config.toml}"
fabriek_operator_config_path() {
	if [ -n "${FABRIEK_CONFIG:-}" ]; then
		printf '%s\n' "$FABRIEK_CONFIG"
		return 0
	fi
	local own="${XDG_CONFIG_HOME:-$HOME/.config}/fabriek/config.toml"
	if [ ! -f "$own" ] && [ -f "$FABRIEK_HOST_CONFIG" ]; then
		printf '%s\n' "$FABRIEK_HOST_CONFIG"
		return 0
	fi
	printf '%s\n' "$own"
}

## The schema, built around the one resources table so that what an operator
## may cap and what a factory may ask for cannot drift apart.
fabriek_operator_config_program() {
	printf 'def capFields: %s;\n' "$(fabriek_resource_field_names_json)"
	cat <<'JQ'
## A factory's entry is its path, and may be the whole declaration in
## fabriek.toml's own words (ADR-061 point 1), which the declaration's
## own schema checks once the entry is one. Specialists and skills are
## ADR-042's keys spelled in TOML, less lsp, which a bare name cannot say.
def schema:
  { top: ["caps", "factories", "credentials", "models", "specialists", "skills", "catalogues"]
  , factory: ["path", "roles", "workflows", "resources", "decider", "catalogue"]
  , credential: ["header", "file"]
  , specialist: ["extends", "tools", "skills", "prompt"]
  , skill: ["tools", "skill"]
  };
def names($v; $what): if ($v | type) != "array" or ($v | map(type != "string") | any)
  then ["\($what) must be a list of names"] else [] end;

. as $c
| [
    unknown($c; schema.top; "config"),
    unknown(($c.caps? // {}); capFields; "caps"),
    ((if ($c.factories | type) == "object" then $c.factories else {} end)
     | to_entries | map(
       .key as $f | .value as $v |
       [ unknown($v; schema.factory; "factory \($f)"),
         (if ($v.path? | type) != "string" or ($v.path | length) == 0
          then ["factory \($f): is registered here with no path"] else [] end)
       ] | cat) | cat),
    ((if ($c.specialists | type) == "object" then $c.specialists else {} end)
     | to_entries | map(
       .key as $n | .value as $v |
       [ unknown($v; schema.specialist; "specialist \($n)"),
         (if $v.extends? then names($v.extends; "specialist \($n): extends") else [] end),
         (if $v.tools? then names($v.tools; "specialist \($n): tools") else [] end),
         (if $v.skills? then names($v.skills; "specialist \($n): skills") else [] end),
         (if ($v.prompt? // null) != null and ($v.prompt | type) != "string"
          then ["specialist \($n): prompt must be a path or text"] else [] end)
       ] | cat) | cat),
    ((if ($c.skills | type) == "object" then $c.skills else {} end)
     | to_entries | map(
       .key as $n | .value as $v |
       [ unknown($v; schema.skill; "skill \($n)"),
         (if $v.tools? then names($v.tools; "skill \($n): tools") else [] end),
         (if ($v.skill? | type) != "string" or ($v.skill | length) == 0
          then ["skill \($n): names no SKILL.md, by path or as text"] else [] end)
       ] | cat) | cat),
    (if ($c.catalogues? // null) != null then names($c.catalogues; "catalogues") else [] end),
    ((if ($c.credentials | type) == "object" then $c.credentials else {} end)
     | to_entries | map(
       .key as $e | .value as $v |
       [ unknown($v; schema.credential; "credential \($e)"),
         (if ($v.header? | type) != "string" or ($v.header | length) == 0
          then ["credential \($e): says no header to carry it in"] else [] end),
         (if ($v.file? | type) != "string" or ($v.file | length) == 0
          then ["credential \($e): says no file to read it from"] else [] end)
       ] | cat) | cat),
    ## The model a session starts on, per endpoint, the operator's to name
    ## beside what it allows and holds a credential for (ADR-029 pins the
    ## agent, not the model). A model id is one word.
    ((if ($c.models | type) == "object" then $c.models else {} end)
     | to_entries | map(
       .key as $e | .value as $v |
       (if ($v | type) != "string" or ($v | test("^[A-Za-z0-9][A-Za-z0-9._:-]*$") | not)
        then ["model for \($e): is not a model id"] else [] end)) | cat)
  ] | cat | .[]
JQ
}

## The operator's config as JSON, checked. Absent is refused rather than read
## as empty: no ceilings would mean a repository gets whatever it asked for,
## and a mistyped path should not be the way that happens.
fabriek_operator_config() {
	local file="${1:-$(fabriek_operator_config_path)}" json failed=0

	if [ ! -f "$file" ]; then
		echo "fabriek: no operator config at $file" >&2
		return 1
	fi

	## The one TOML reader (repo-declaration.sh), so this file and a
	## repository's fabriek.toml are refused the same way.
	if ! json="$(fabriek_toml_json "$file" 2>/dev/null)"; then
		echo "fabriek: $file is not TOML" >&2
		return 1
	fi

	printf '%s' "$json" |
		fabriek_schema_check "$(fabriek_operator_config_program)" "operator config" >/dev/null || failed=1

	local factory
	while IFS= read -r factory; do
		[ -n "$factory" ] || continue
		fabriek_name_ok "$factory" && continue
		echo "fabriek: $file registers $factory, which is not a usable factory name" >&2
		failed=1
	done < <(printf '%s' "$json" | jq -r '(.factories // {}) | keys[]?')

	## A factory declared whole here is held to the declaration's own
	## schema (ADR-061 point 1), so a role's mistake is named as the
	## repository's would be.
	while IFS= read -r factory; do
		[ -n "$factory" ] || continue
		fabriek_operator_declaration_of "$json" "$factory" >/dev/null 2>"$file.err" && continue
		sed "s/^fabriek: /fabriek: factory $factory: /" "$file.err" >&2
		failed=1
	done < <(printf '%s' "$json" | jq -r '(.factories // {}) | to_entries[] | select(.value | has("roles") or has("workflows") or has("resources") or has("decider") or has("catalogue")) | .key')
	rm -f "$file.err"

	## The operator's specialists and skills (ADR-061 point 3): names in
	## the alphabet a catalogue directory would be, and a prompt, a skill
	## file or a catalogue given as a path at a path that is there. A value
	## that starts with / is a path; anything else is the text itself.
	local name value
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		fabriek_name_ok "$name" && continue
		echo "fabriek: $file declares a specialist or skill named $name, which is not a usable name" >&2
		failed=1
	done < <(printf '%s' "$json" | jq -r '((.specialists // {}) | keys[]?), ((.skills // {}) | keys[]?)')
	while IFS=$'\t' read -r name value; do
		[ -n "$value" ] || continue
		case "$value" in
		/*) [ -f "$value" ] || {
			echo "fabriek: $name: $value does not exist" >&2
			failed=1
		} ;;
		esac
	done < <(printf '%s' "$json" | jq -r '
	  ((.specialists // {}) | to_entries[] | select(.value.prompt) | "specialist \(.key)\t\(.value.prompt)"),
	  ((.skills // {}) | to_entries[] | select(.value.skill) | "skill \(.key)\t\(.value.skill)")')
	while IFS= read -r value; do
		[ -n "$value" ] || continue
		[ -d "$value" ] || {
			echo "fabriek: catalogue $value does not exist" >&2
			failed=1
		}
	done < <(printf '%s' "$json" | jq -r '(.catalogues // [])[]')

	## A credential is keyed by the endpoint it opens and carried in a named
	## header, and both reach somewhere that would otherwise have to escape
	## them: the endpoint becomes a location in the proxy and the header
	## becomes a directive beside it.
	local endpoint header
	while IFS=$'\t' read -r endpoint header; do
		[ -n "$endpoint" ] || continue
		if ! fabriek_host_ok "$endpoint"; then
			echo "fabriek: $file holds a credential for $endpoint, which is not a host" >&2
			failed=1
		fi
		if ! fabriek_header_name_ok "$header"; then
			echo "fabriek: $file carries the credential for $endpoint in $header, which is not a header name" >&2
			failed=1
		fi
	done < <(printf '%s' "$json" |
		jq -r '(.credentials // {}) | to_entries[]? | "\(.key)\t\(.value.header // "")"')

	## A model is keyed by the endpoint it is asked of, which reaches the
	## same places a credential's does.
	while IFS= read -r endpoint; do
		[ -n "$endpoint" ] || continue
		if ! fabriek_host_ok "$endpoint"; then
			echo "fabriek: $file names a model for $endpoint, which is not a host" >&2
			failed=1
		fi
	done < <(printf '%s' "$json" | jq -r '(.models // {}) | keys[]?')

	[ "$failed" -eq 0 ] || return 1
	printf '%s\n' "$json"
}

## Each reader below captures the config before shaping it rather than piping
## into jq. A pipeline reports its last command's verdict, so piping a refused
## config into jq would print the refusal and then succeed.

## What a factory may cost on this machine. An operator who set no ceilings has
## none, which is theirs to decide; what they cannot have is one they misspelled.
fabriek_operator_caps() {
	local json
	json="$(fabriek_operator_config "${1:-}")" || return 1
	printf '%s' "$json" | jq '.caps // {}'
}

## The factories registered on this machine, one per line.
fabriek_operator_factories() {
	local json
	json="$(fabriek_operator_config "${1:-}")" || return 1
	printf '%s' "$json" | jq -r '(.factories // {}) | keys[]?'
}

## Where a registered factory's repository is. A factory nobody registered here
## is refused by name rather than guessed at from the working directory.
fabriek_operator_factory_path() {
	local file="$1" factory="$2" path
	fabriek_name_ok "$factory" || {
		echo "fabriek: invalid factory name: $factory" >&2
		return 1
	}
	local json
	json="$(fabriek_operator_config "$file")" || return 1
	path="$(printf '%s' "$json" | jq -r --arg f "$factory" '.factories[$f].path // empty')"
	if [ -z "$path" ]; then
		echo "fabriek: no factory registered here as $factory" >&2
		return 1
	fi
	printf '%s\n' "$path"
}

## The credentials this operator holds, keyed by the endpoint each one opens.
## An operator holding none holds none: not every host wants authenticating to,
## and a factory reaching one that does not is not a mistake.
fabriek_operator_credentials() {
	local json
	json="$(fabriek_operator_config "${1:-}")" || return 1
	printf '%s' "$json" | jq '.credentials // {}'
}

## The model a session starts on, per endpoint; none is not an error.
fabriek_operator_models() {
	local json
	json="$(fabriek_operator_config "${1:-}")" || return 1
	printf '%s' "$json" | jq '.models // {}'
}

## A factory's declaration from the operator's file (ADR-061 point 1): the
## entry less what is the register's (path, autoStart), named after the
## factory, validated as the repository's would be. Prints the expanded
## declaration; returns 2, printing nothing, when the entry is a path and
## no more, which is a factory declared elsewhere and not a fault.
##
## fabriek_operator_declaration_of <config.json> <factory>
fabriek_operator_declaration_of() {
	local json="$1" factory="$2" entry
	entry="$(printf '%s' "$json" | jq -c --arg f "$factory" '.factories[$f] // {} | del(.path, .autoStart)')"
	[ "$entry" != "{}" ] || return 2
	printf '%s' "$entry" | jq --arg f "$factory" '. + {name: $f}' | fabriek_declaration_validate
}

## fabriek_operator_declaration <config.toml> <factory>: the same, from the file.
fabriek_operator_declaration() {
	local json
	json="$(fabriek_operator_config "$1")" || return 1
	fabriek_operator_declaration_of "$json" "$2"
}

## The operator's own specialists, skills and catalogue directories
## (ADR-061 points 3 and 4). None is none.
fabriek_operator_specialists() {
	local json
	json="$(fabriek_operator_config "${1:-}")" || return 1
	printf '%s' "$json" | jq '.specialists // {}'
}

fabriek_operator_skills() {
	local json
	json="$(fabriek_operator_config "${1:-}")" || return 1
	printf '%s' "$json" | jq '.skills // {}'
}

## One directory per line.
fabriek_operator_catalogues() {
	local json
	json="$(fabriek_operator_config "${1:-}")" || return 1
	printf '%s' "$json" | jq -r '(.catalogues // [])[]'
}

## The factory registered here for a repository, by its resolved path, or
## nothing when none is. What lets check, given a path, find the entry that
## may declare it.
##
## fabriek_operator_factory_for_path <config.json> <absolute repo path>
fabriek_operator_factory_for_path() {
	local json="$1" repo="$2" factory path
	while IFS=$'\t' read -r factory path; do
		[ -n "$path" ] || continue
		[ "$(cd "$path" 2>/dev/null && pwd)" = "$repo" ] || continue
		printf '%s\n' "$factory"
		return 0
	done < <(printf '%s' "$json" | jq -r '(.factories // {}) | to_entries[] | "\(.key)\t\(.value.path // "")"')
	return 1
}

## Where a factory's declaration is (ADR-061 point 2): the operator's file
## when the entry for this factory carries one, the repository's
## fabriek.toml otherwise. Prints the file. The config may be absent
## (check on a repository nobody registered): then the repository is the
## one place. Says nothing about a double declaration; resolve does.
##
## fabriek_declaration_source <config.toml-or-empty> <factory-or-empty> <repo>
fabriek_declaration_source() {
	local config="$1" factory="$2" repo="$3" json
	if [ -n "$config" ] && [ -f "$config" ] && json="$(fabriek_operator_config "$config" 2>/dev/null)"; then
		[ -n "$factory" ] || factory="$(fabriek_operator_factory_for_path "$json" "$repo")" || factory=""
		if [ -n "$factory" ] && printf '%s' "$json" | jq -e --arg f "$factory" \
			'.factories[$f] | has("roles") or has("workflows") or has("resources") or has("decider") or has("catalogue")' >/dev/null; then
			printf '%s\n' "$config"
			return 0
		fi
	fi
	printf '%s/fabriek.toml\n' "$repo"
}

## The declaration itself, from wherever it is, validated: the operator's
## entry named after the factory, or the repository's file at the rev;
## refused naming both when both declare it.
##
## fabriek_declaration_resolve <config.toml-or-empty> <factory-or-empty> <repo> <rev>
fabriek_declaration_resolve() {
	local config="$1" factory="$2" repo="$3" rev="$4" source json
	source="$(fabriek_declaration_source "$config" "$factory" "$repo")"
	if [ "$source" = "$repo/fabriek.toml" ]; then
		fabriek_declaration_read "$repo" "$rev"
		return
	fi
	json="$(fabriek_operator_config "$config")" || return 1
	[ -n "$factory" ] || factory="$(fabriek_operator_factory_for_path "$json" "$repo")"
	if git -C "$repo" cat-file -e "$rev:fabriek.toml" 2>/dev/null; then
		echo "fabriek: $factory is declared twice: in $config and in $repo/fabriek.toml at $rev; a factory is declared once" >&2
		return 1
	fi
	fabriek_operator_declaration_of "$json" "$factory"
}
