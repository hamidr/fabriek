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

## fabriek_credential_toml <config.json> <factory> <remote> <rev> <hostSystem>
fabriek_credential_toml() {
	local config="$1" factory="$2" remote="$3" rev="$4" host_system="$5"
	jq -r --arg factory "$factory" --arg remote "$remote" --arg rev "$rev" --arg host "$host_system" '
	  def table(name; obj): "[\(name)]", (obj | to_entries[] | "\(.key | tojson) = \(.value | tojson)"), "";
	  "## Written by fabriek up from the operator'"'"'s config and the repository'"'"'s pin.",
	  "## Not edited by hand; fabriek up -u moves [pin].",
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
	  (if .embedder.url then ("[embedder]", "url = \(.embedder.url | tojson)", "") else empty end)
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
