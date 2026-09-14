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
def schema:
  { top: ["caps", "factories", "credentials", "models"]
  , factory: ["path"]
  , credential: ["header", "file"]
  };

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

	if ! json="$(FABRIEK_CONFIG_TOML="$(cat "$file")" nix eval --impure --json \
		--expr 'builtins.fromTOML (builtins.getEnv "FABRIEK_CONFIG_TOML")' 2>/dev/null)"; then
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
