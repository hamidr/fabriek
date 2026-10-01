# shellcheck shell=bash
## A factory's dependency cache (ADR-046): what of a repository's lockfile
## the host fetches at render, and from where. A fixed-output hash checks
## what came back, not where the request went, so an artifact is fetched
## only from an allowed registry, named with its integrity; anything else
## refuses the lockfile by entry before a single request is sent.
##
## Sourced by store path into fabriek-container; the suite sources it.

## The registries the host fetches npm artifacts from, as an origin.
FABRIEK_NPM_REGISTRIES='["registry.npmjs.org"]'

## The jq that reads a package-lock.json's artifacts: the entries installed
## under a node_modules, but for a link to the repository's own code and a
## bundled one, which the tarball that bundles it carries. The root and a
## workspace's members are the repository itself.
_fabriek_npm_entries='
	.packages // {} | to_entries[]
	| select((.key | test("(^|/)node_modules/")) and (.value.link | not) and (.value.inBundle | not))'

## Each refused entry of a lockfile, one line each, and failure when any
## is; nothing and success when every artifact may be fetched.
## fabriek_npm_lock_refused <package-lock.json>
fabriek_npm_lock_refused() {
	local lock="$1" refused
	refused="$(jq -r --argjson allowed "$FABRIEK_NPM_REGISTRIES" '
		if (.lockfileVersion // 1) < 2 then
			"package-lock.json: lockfileVersion \(.lockfileVersion // 1) is not read; npm 7 and later write 2 or 3"
		else
			'"$_fabriek_npm_entries"'
			| .key as $entry | .value
			| if (.resolved | type) != "string" then "\($entry): no resolved url"
			  else
				(.resolved | capture("^(?<scheme>[a-z]+)://(?<host>[^/:?#]+)") // {scheme: "", host: .}) as $at
				| if $at.scheme != "https" or ($allowed | index($at.host) | not) then
					"\($entry): \(if $at.scheme == "https" then $at.host else "\($at.scheme)://\($at.host)" end) is not an allowed registry"
				  elif (.integrity | type) != "string" then "\($entry): no integrity"
				  else empty end
			  end
		end' "$lock")" || return 1
	[ -z "$refused" ] && return 0
	printf '%s\n' "$refused"
	return 1
}

## The artifacts a lockfile names, each once, as the JSON list npm-cache.nix
## reads: url and integrity. Run only on a lockfile nothing was refused in.
## fabriek_npm_lock_artifacts <package-lock.json>
fabriek_npm_lock_artifacts() {
	jq -c '[ '"$_fabriek_npm_entries"' | {url: .value.resolved, integrity: .value.integrity} ] | unique_by(.url)' "$1"
}

## The store path of a factory's npm cache, built on this host from the
## package-lock.json at the pin; nothing when the commit has none. A
## lockfile with an entry off the allowlist is refused by entry on stderr
## and nothing of it is built. Restricted like a profile's build: fabriek
## and nixpkgs are read by path, and the fetches are fixed-output, so
## evaluation reaches nothing the lockfile names.
## fabriek_npm_cache_build <clone> <rev> <self> <nixpkgs> <system>
fabriek_npm_cache_build() {
	local clone="$1" rev="$2" self="$3" nixpkgs="$4" system="$5" lock artifacts
	git -C "$clone" cat-file -e "$rev:package-lock.json" 2>/dev/null || return 0
	lock="$(mktemp)"
	git -C "$clone" show "$rev:package-lock.json" >"$lock" || {
		rm -f "$lock"
		return 1
	}
	if ! fabriek_npm_lock_refused "$lock" >&2; then
		rm -f "$lock"
		return 1
	fi
	artifacts="$(fabriek_npm_lock_artifacts "$lock")"
	rm -f "$lock"
	local expr
	expr="import $self/modules/npm-cache.nix {"
	expr="$expr nixpkgs = $(fabriek_nix_string "$nixpkgs"); system = $(fabriek_nix_string "$system");"
	expr="$expr artifacts = builtins.fromJSON $(fabriek_nix_string "$artifacts"); }"
	nix build --no-link --print-out-paths --impure --restrict-eval -I "$self" -I "$nixpkgs" --expr "$expr"
}
