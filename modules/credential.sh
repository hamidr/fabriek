# shellcheck shell=bash
## The credential a machine boots with (ADR-057 point 3): the operator's
## config.toml projected for one factory, plus the pin. One TOML file, so a
## person reading it beside config.toml sees the same spelling; read on the
## machine by the one TOML reader (repo-declaration.sh). Never a secret's
## value, and not even its path: the value goes over ssh after boot, and
## the path is the host's business (ADR-025).
##
## Sourced by store path into fabriek beside operator-config.sh and
## repo-declaration.sh.

## A value or a table as TOML (ADR-061 point 6): what the operator's file
## says in TOML's own words goes back out in them, nested tables and
## arrays of tables included, so the reader on the machine takes the
## declaration back whole. Keys are quoted always: an endpoint has dots.
##
## fabriek_credential_toml <config.json> <factory> <remote> <rev> <hostSystem>
fabriek_credential_toml() {
	local config="$1" factory="$2" remote="$3" rev="$4" host_system="$5"
	jq -r --arg factory "$factory" --arg remote "$remote" --arg rev "$rev" --arg host "$host_system" '
	  def scalar: type == "string" or type == "number" or type == "boolean"
	    or (type == "array" and (map(type == "object") | any | not));
	  def value: if type == "array" then "[" + (map(value) | join(", ")) + "]" else tojson end;
	  def tables(prefix):
	    . as $o
	    | (prefix | if . == "" then "" else . + "." end) as $p
	    | [ (if prefix == "" then empty else "[\(prefix)]" end),
	        ($o | to_entries[] | select(.value | scalar) | "\(.key | tojson) = \(.value | value)"),
	        (if prefix == "" then empty else "" end),
	        ($o | to_entries[] | select(.value | type == "object") | .key as $k | .value | tables($p + ($k | tojson))),
	        ($o | to_entries[] | select(.value | type == "array" and (map(type == "object") | any))
	          | .key as $k | .value[] | "[[\($p)\($k | tojson)]]", (to_entries[] | "\(.key | tojson) = \(.value | value)"), "")
	      ] | .[];
	  def table(name; obj): "[\(name)]", (obj | to_entries[] | "\(.key | tojson) = \(.value | tojson)"), "";
	  "## Written by fabriek up from the operator'"'"'s config and the repository'"'"'s pin.",
	  "## Not edited by hand; fabriek up -u moves [pin].",
	  "",
	  ## Top-level values come before any table, or TOML reads them into
	  ## the last one.
	  "catalogues = \((.catalogues // []) | value)",
	  "",
	  "[factory]",
	  "name = \($factory | tojson)",
	  "hostSystem = \($host | tojson)",
	  "",
	  "[repository]",
	  "path = \(.factories[$factory].path | tojson)",
	  "remote = \($remote | tojson)",
	  "",
	  "[pin]",
	  "rev = \($rev | tojson)",
	  "",
	  table("caps"; .caps // {}),
	  table("credentials"; (.credentials // {}) | map_values(.header)),
	  table("models"; .models // {}),
	  (if .embedder.url then ("[embedder]", "url = \(.embedder.url | tojson)", "") else empty end),
	  ## The factory declared whole in the operator'"'"'s file, when it is
	  ## (ADR-061): the entry less the register'"'"'s keys, named. The
	  ## repository'"'"'s declaration is the clone'"'"'s to read.
	  (.factories[$factory] | del(.path, .autoStart)
	    | if . == {} then empty else (. + {name: $factory}) | tables("declaration") end),
	  ({specialists: (.specialists // {})} | tables("")),
	  ({skills: (.skills // {})} | tables(""))
	' "$config"
}

## The pin a credential carries.
fabriek_credential_rev() {
	sed -n 's/^rev = "\(.*\)"$/\1/p' "$1"
}

## Move the pin, in place and by rename, leaving every other line as it was.
fabriek_credential_pin() {
	local file="$1" rev="$2"
	sed "s/^rev = \".*\"$/rev = \"$rev\"/" "$file" >"$file.new" && mv "$file.new" "$file"
}
