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
	printf 'def capFields: %s;\n' "$(fabriek_cap_field_names_json)"
	cat <<'JQ'
## A factory's entry is its path, and may be the whole declaration in
## fabriek.toml's own words (ADR-061 point 1), which the declaration's
## own schema checks once the entry is one. Specialists and skills are
## ADR-042's keys spelled in TOML, less lsp, which a bare name cannot say.
def schema:
  { top: ["caps", "factories", "credentials", "models", "endpoints", "specialists", "skills", "catalogues"]
  , factory: ["path", "roles", "workflows", "resources", "decider", "catalogue"]
  , credential: ["header", "file"]
  , endpoint: ["host", "provider", "api", "compat", "header", "file", "models"]
  , specialist: ["extends", "tools", "skills", "prompt"]
  , skill: ["tools", "skill"]
  , catalogue: ["git", "rev", "narHash", "dir"]
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
    ## A catalogue is a directory, or a git repository at a rev (ADR-062):
    ## a flake reference with no query, no fragment and nobody before the
    ## host, a full commit hash, the tree's hash where a forge serves a
    ## tarball nix checks against nothing, and a dir inside the tree.
    ((if ($c.catalogues | type) == "array" then $c.catalogues else [] end)
     | to_entries | map(
       .key as $i | .value as $v |
       if ($v | type) == "string" then []
       elif ($v | type) != "object" then ["catalogue \($i): is neither a directory nor a git table"]
       else
         [ unknown($v; schema.catalogue; "catalogue \($i)"),
           (if ($v.git? | type) != "string" or ($v.git | length) == 0
            then ["catalogue \($i): names no git repository"]
            elif ($v.git | test("[?#]"))
            then ["catalogue \($i): git carries a query or a fragment; rev is the one pin"]
            elif ($v.git | test("^[a-z+]+://[^/]*@"))
            then ["catalogue \($i): git carries a user before the host; a forge's access is the host's git and ssh configuration, never this file"]
            else [] end),
           (if ($v.rev? | type) != "string" or ($v.rev | test("^[0-9a-f]{40}$") | not)
            then ["catalogue \($i): rev must be forty hex digits"] else [] end),
           (if ($v.narHash? // null) != null and (($v.narHash | type) != "string" or ($v.narHash | test("^sha256-[A-Za-z0-9+/]+=*$") | not))
            then ["catalogue \($i): narHash must be sha256- and base64, as nix prints it"]
            elif ($v.narHash? // null) == null and (($v.git? // "") | test("^(github|gitlab|sourcehut):"))
            then ["catalogue \($i): a forge reference is pinned by narHash too; nix checks a forge's tarball against nothing"]
            else [] end),
           (if ($v.dir? // null) != null and (($v.dir | type) != "string" or ($v.dir | test("^/")) or ($v.dir | split("/") | index("..") != null))
            then ["catalogue \($i): dir must be a path inside the tree"] else [] end)
         ] | cat
       end) | cat),
    (if ($c.catalogues? // null) != null and ($c.catalogues | type) != "array" then ["catalogues must be a list"] else [] end),
    ((if ($c.credentials | type) == "object" then $c.credentials else {} end)
     | to_entries | map(
       .key as $e | .value as $v |
       [ unknown($v; schema.credential; "credential \($e)"),
         (if ($v.header? | type) != "string" or ($v.header | length) == 0
          then ["credential \($e): says no header to carry it in"] else [] end),
         (if ($v.file? | type) != "string" or ($v.file | length) == 0
          then ["credential \($e): says no file to read it from"] else [] end)
       ] | cat) | cat),
    ## An endpoint declared once, by name (ADR-072 point 1): where it is,
    ## which pi provider answers it, the credential's header and file, and
    ## the model names a role may pick. A name has no dot, so it cannot be
    ## taken for a host, and no host is declared twice, here or in the
    ## credentials and models tables.
    ((if ($c.endpoints | type) == "object" then $c.endpoints else {} end) as $e
     | [ ($e | to_entries[] | select(.key | test("^[a-zA-Z0-9][a-zA-Z0-9-]*$") | not)
          | "endpoint \(.key): is not a name (letters, digits and dashes, no dot)"),
         ($e | to_entries[] | .key as $n | .value as $v |
          if ($v | type) != "object" then "endpoint \($n): is not a table" else
          ( unknown($v; schema.endpoint; "endpoint \($n)")[],
            (if ($v.host? | type) != "string" or ($v.host | length) == 0
             then "endpoint \($n): says no host" else empty end),
            (if ($v.provider? | type) != "string" or ($v.provider | test("^[a-z][a-z0-9-]*$") | not)
             then "endpoint \($n): says no provider that answers it" else empty end),
            (if ($v.api? // null) != null and (($v.api | type) != "string" or ($v.api | test("^[a-z][a-z0-9-]*$") | not))
             then "endpoint \($n): api is not an api name" else empty end),
            (if ($v.compat? // null) != null
                and (($v.compat | type) != "object" or ($v.compat | [.[] | type | select(. == "object" or . == "array")] | length > 0))
             then "endpoint \($n): compat must be a table of plain values" else empty end),
            (if (($v.header? // null) == null) != (($v.file? // null) == null)
             then "endpoint \($n): carries a header or a file without the other" else empty end),
            (if ($v.models? | type) != "object" or ($v.models.default? | type) != "string"
             then "endpoint \($n): models says no default" else
             ($v.models | to_entries[] | select((.value | type) != "string" or (.value | test("^[A-Za-z0-9][A-Za-z0-9._:-]*$") | not))
              | "endpoint \($n): model \(.key) is not a model id") end)
          ) end),
         ([$e[]? | .host? | strings] | group_by(.) | .[] | select(length > 1) | "host \(.[0]) is declared by two endpoints"),
         ($e[]? | .host? | strings | select(. as $h | (($c.credentials // {}) | has($h)) or (($c.models // {}) | has($h)))
          | "host \(.) is an endpoint and also has a credential or a model of its own; declare it in one place")
       ] | map([.]) | cat),
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

## What a named endpoint stands for everywhere else (ADR-072 point 1): its
## host's credential, start model and endpoint row, where the proxy, the
## credential files and the clamp already look, and its name in an egress
## list turned into its host. `names` stays beside, so a repository's egress
## can be turned the same way where the declaration is read. A config naming
## no endpoint passes through untouched.
# shellcheck disable=SC2016 # a jq program, not a shell expansion
FABRIEK_OPERATOR_EXPAND='
  (.endpoints // {}) as $e
  | if $e == {} then . else
    ($e | with_entries({ key: .key, value: .value.host })) as $names
    | def host: if type == "string" then ($names[.] // .) else . end;
      .names = $names
    | .credentials = ((.credentials // {}) + ([$e[] | select(.header != null) | { key: .host, value: { header: .header, file: .file } }] | from_entries))
    | .models = ((.models // {}) + ([$e[] | { key: .host, value: .models.default }] | from_entries))
    | .endpoints = ([$e[] | { key: .host, value: del(.host, .header, .file) }] | from_entries)
    | (if .caps.egress? then .caps.egress |= map(host) else . end)
    | (if .factories then .factories |= map_values(if .resources.egress? then .resources.egress |= map(host) else . end) else . end)
    end'

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
	local err
	err="$(mktemp)"
	while IFS= read -r factory; do
		[ -n "$factory" ] || continue
		fabriek_operator_declaration_of "$json" "$factory" >/dev/null 2>"$err" && continue
		sed "s/^fabriek: /fabriek: factory $factory: /" "$err" >&2
		failed=1
	done < <(printf '%s' "$json" | jq -r '(.factories // {}) | to_entries[] | select(.value | has("roles") or has("workflows") or has("resources") or has("decider") or has("catalogue")) | .key')
	rm -f "$err"

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
	done < <(printf '%s' "$json" | jq -r '(.catalogues // [])[] | strings')

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

	## An endpoint's host reaches the proxy's locations and its header the
	## directive beside them, as a credential's key and header do.
	local named_host named_header
	while IFS=$'\t' read -r named_host named_header; do
		[ -n "$named_host" ] || continue
		if ! fabriek_host_ok "$named_host"; then
			echo "fabriek: $file declares an endpoint at $named_host, which is not a host" >&2
			failed=1
		fi
		if [ -n "$named_header" ] && ! fabriek_header_name_ok "$named_header"; then
			echo "fabriek: $file carries the credential for $named_host in $named_header, which is not a header name" >&2
			failed=1
		fi
	done < <(printf '%s' "$json" |
		jq -r '(.endpoints // {}) | to_entries[]? | "\(.value.host? // "")\t\(.value.header? // "")"')

	[ "$failed" -eq 0 ] || return 1
	printf '%s' "$json" | jq -c "$FABRIEK_OPERATOR_EXPAND"
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

## The endpoints this operator declares beyond the shipped three, as rows
## keyed by host; none is not an error.
fabriek_operator_endpoints() {
	local json
	json="$(fabriek_operator_config "${1:-}")" || return 1
	printf '%s' "$json" | jq -c '.endpoints // {}'
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

## One directory per line; a git catalogue (ADR-062) as its table, one
## line of JSON.
fabriek_operator_catalogues() {
	local json
	json="$(fabriek_operator_config "${1:-}")" || return 1
	printf '%s' "$json" | jq -rc '(.catalogues // [])[] | if type == "string" then . else tojson end'
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

## A git catalogue fetched on this host (ADR-062 point 2): the reference at
## its rev through nix's own fetcher, the tree's hash checked against the
## one the operator wrote, the dir found in it. Prints the store path of
## the catalogue directory and the hash fetched, tab-separated; refuses
## naming the reference and the rev.
##
## fabriek_catalogue_fetch <git> <rev> <narHash-or-empty> <dir-or-empty>
fabriek_catalogue_fetch() {
	local git="$1" rev="$2" want="$3" subdir="$4" answer stored got
	answer="$("${FABRIEK_NIX:-nix}" flake prefetch --json "$git?rev=$rev" 2>/dev/null)" || {
		echo "fabriek: catalogue $git at $rev could not be fetched" >&2
		return 1
	}
	stored="$(jq -r .storePath <<<"$answer")"
	got="$(jq -r .hash <<<"$answer")"
	if [ -n "$want" ] && [ "$want" != "$got" ]; then
		echo "fabriek: catalogue $git at $rev: the tree fetched has hash $got, not $want" >&2
		return 1
	fi
	if [ -n "$subdir" ] && [ ! -d "$stored/$subdir" ]; then
		echo "fabriek: catalogue $git at $rev: the tree has no $subdir" >&2
		return 1
	fi
	printf '%s\t%s\n' "$stored${subdir:+/$subdir}" "$got"
}

