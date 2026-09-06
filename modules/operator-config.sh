# shellcheck shell=bash
## The one file the operator owns (ADR-020 point 4).
##
## What a factory may cost on this machine, and which factories live here. The
## same file on Linux and on macOS, with no NixOS module to import, no flake to
## scaffold and no rebuild to run: reaching cageworks for the first time is
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

## Where the operator's config lives. CAGEWORKS_CONFIG overrides it, which is
## what the suite uses and what an operator with more than one of them needs.
cageworks_operator_config_path() {
	if [ -n "${CAGEWORKS_CONFIG:-}" ]; then
		printf '%s\n' "$CAGEWORKS_CONFIG"
		return 0
	fi
	printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/cageworks/config.toml"
}

## The schema, built around the one resources table so that what an operator
## may cap and what a factory may ask for cannot drift apart.
cageworks_operator_config_program() {
	printf 'def capFields: %s;\n' "$(cageworks_resource_field_names_json)"
	cat <<'JQ'
def schema: { top: ["caps", "factories"], factory: ["path"] };

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
       ] | cat) | cat)
  ] | cat | .[]
JQ
}

## The operator's config as JSON, checked. Absent is refused rather than read
## as empty: no ceilings would mean a repository gets whatever it asked for,
## and a mistyped path should not be the way that happens.
cageworks_operator_config() {
	local file="${1:-$(cageworks_operator_config_path)}" json failed=0

	if [ ! -f "$file" ]; then
		echo "cageworks: no operator config at $file" >&2
		return 1
	fi

	if ! json="$(CAGEWORKS_CONFIG_TOML="$(cat "$file")" nix eval --impure --json \
		--expr 'builtins.fromTOML (builtins.getEnv "CAGEWORKS_CONFIG_TOML")' 2>/dev/null)"; then
		echo "cageworks: $file is not TOML" >&2
		return 1
	fi

	printf '%s' "$json" |
		cageworks_schema_check "$(cageworks_operator_config_program)" "operator config" >/dev/null || failed=1

	local factory
	while IFS= read -r factory; do
		[ -n "$factory" ] || continue
		cageworks_name_ok "$factory" && continue
		echo "cageworks: $file registers $factory, which is not a usable factory name" >&2
		failed=1
	done < <(printf '%s' "$json" | jq -r '(.factories // {}) | keys[]?')

	[ "$failed" -eq 0 ] || return 1
	printf '%s\n' "$json"
}

## Each reader below captures the config before shaping it rather than piping
## into jq. A pipeline reports its last command's verdict, so piping a refused
## config into jq would print the refusal and then succeed.

## What a factory may cost on this machine. An operator who set no ceilings has
## none, which is theirs to decide; what they cannot have is one they misspelled.
cageworks_operator_caps() {
	local json
	json="$(cageworks_operator_config "${1:-}")" || return 1
	printf '%s' "$json" | jq '.caps // {}'
}

## The factories registered on this machine, one per line.
cageworks_operator_factories() {
	local json
	json="$(cageworks_operator_config "${1:-}")" || return 1
	printf '%s' "$json" | jq -r '(.factories // {}) | keys[]?'
}

## Where a registered factory's repository is. A factory nobody registered here
## is refused by name rather than guessed at from the working directory.
cageworks_operator_factory_path() {
	local file="$1" factory="$2" path
	cageworks_name_ok "$factory" || {
		echo "cageworks: invalid factory name: $factory" >&2
		return 1
	}
	local json
	json="$(cageworks_operator_config "$file")" || return 1
	path="$(printf '%s' "$json" | jq -r --arg f "$factory" '.factories[$f].path // empty')"
	if [ -z "$path" ]; then
		echo "cageworks: no factory registered here as $factory" >&2
		return 1
	fi
	printf '%s\n' "$path"
}
