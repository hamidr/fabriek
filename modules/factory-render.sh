# shellcheck shell=bash
## What prepare renders from the declaration at boot (ADR-057 point 4).
##
## The build used to render each of these into the image: the bridge plan
## and the set the bridge's rules key on (bridge.nix), the proxy's locations
## and ceiling (proxy.nix), the model pi starts on and the models.json that
## points it at the proxy, and a pi directory per role (floor.nix). One image
## now serves every factory, so the same text comes from here, from the
## clamped declaration the machine was handed, written under the state
## directory where the services include it. Same shapes as before, so the
## machine program, the executor and the proofs read what they read.
##
## Sourced by store path into fabriek-container beside names.sh; the suite
## sources it with nixcage-container stubbed for the veth's name.

## The bridge plan: the machine at .1, the decider at .2, a role's cage at
## .10 onward in name order, and where the three services answer. One copy,
## for the executor that starts sessions and the rules below, so the two
## cannot disagree. The net is the bridge's own, from the address the host
## gave it (ADR-067 point 3): each factory has a bridge, and a plan laid
## on a fixed net put every factory on the first's (seen 2026-09-22).
##
## fabriek_render_bridge_plan <declaration.json> <bridge> <host> <proxyPort> <forgejoPort> <busPort>
fabriek_render_bridge_plan() {
	local declaration="$1" bridge="$2" host="$3" proxy_port="$4" forgejo_port="$5" bus_port="$6"
	## .254 is the factory's machine's own address on the bridge (ADR-070),
	## so a role's is at most .253.
	local roles
	roles="$(jq '.roles | length' "$declaration")"
	if [ "$roles" -gt 244 ]; then
		echo "fabriek: the declaration has $roles roles; a factory's bridge holds 244" >&2
		return 1
	fi
	## -S: keys in name order, as the build's toJSON wrote them, so the set
	## below and the executor's reading of the plan meet what they met.
	jq -cS --arg bridge "$bridge" --arg net "${host%.*}" --arg proxy "$proxy_port" --arg forgejo "$forgejo_port" --arg bus "$bus_port" '
	  (.roles | keys) as $roles
	  | { bridge: $bridge,
	      host: "\($net).1",
	      prefix: 24,
	      cages: ({ decider: "\($net).2" }
	        + ([$roles | to_entries[] | { key: .value, value: "\($net).\(10 + .key)" }] | from_entries)),
	      proxy: "\($net).1:\($proxy)",
	      forgejo: "\($net).1:\($forgejo)",
	      bus: "\($net).1:\($bus)" }' "$declaration"
}

## The proxy's configuration for one factory: the token ceiling and a
## location per allowed endpoint, each counting what passes and refusing at
## the ceiling. Included by the factory's server on the host. Zero is no
## ceiling. The credential header comes from the file the factory's own
## egress-credentials unit writes under its name (host/proxy.nix), so two
## factories allowing one endpoint never read each other's. pi sends its
## placeholder key as x-api-key whatever the endpoint wants, so an endpoint
## whose credential travels in another header has the placeholder cleared
## (ADR-072 point 6); a gateway may refuse it before reading the real one.
##
## fabriek_render_proxy <declaration.json> [<credential-headers-json>]
fabriek_render_proxy() {
	local declaration="$1" headers="${2:-}" host factory header strip
	[ -n "$headers" ] || headers='{}'
	factory="$(jq -r .name "$declaration")"
	printf "set \$spend_ceiling %s;\n" "$(jq -r '.resources.tokens // 0' "$declaration")"
	while IFS= read -r host; do
		[ -n "$host" ] || continue
		header="$(jq -r --arg h "$host" '.[$h] // "x-api-key" | ascii_downcase' <<<"$headers")"
		strip=""
		[ "$header" = "x-api-key" ] || strip=$'  proxy_set_header x-api-key "";\n'
		cat <<CONF
location /$host/ {
  if (\$spend_over = 1) {
    return 429;
  }
  proxy_pass https://$host/;
  proxy_set_header Host $host;
  proxy_ssl_server_name on;
  proxy_buffering off;
  proxy_set_header Accept-Encoding "";
$strip  js_body_filter spend.count;
  include /run/fabriek-egress/$factory/$host.conf;
}
CONF
	done < <(jq -r '.resources.egress // [] | .[]' "$declaration")
}

## The endpoints pi can be pointed at (ADR-072 point 1): the table fabriek
## ships in endpoints.json, a row per host with the pi provider that answers
## it and the model a session starts on when the operator names none, with
## the operator's own rows on top. A declared row names a provider, and may
## name an api and a compat map; one for a shipped host changes the fields it
## names and keeps the rest. An endpoint outside the table is reachable
## through the proxy and pi is not pointed at it.
##
## fabriek_render_endpoints <declared-endpoints-json>
fabriek_render_endpoints() {
	jq -cn --slurpfile shipped "$FABRIEK_LIB/endpoints.json" --argjson declared "$1" '$shipped[0] * $declared'
}

## The endpoints the declaration allows that pi has a provider for, in the
## table's order. Prints "host<TAB>provider" lines. Two hosts answering as one
## provider are refused: models.json keys a provider by name, so the second
## would replace the first and a session would reach the wrong host.
##
## fabriek_render_routed <declaration.json> <endpoints-json>
fabriek_render_routed() {
	local declaration="$1" endpoints="$2" routed twice
	routed="$(jq -r --argjson endpoints "$endpoints" '
	  (.resources.egress // []) as $allowed
	  | $endpoints | to_entries[] | select(.key as $h | $allowed | index($h) != null)
	  | "\(.key)\t\(.value.provider)"' "$declaration")" || return 1
	twice="$(printf '%s\n' "$routed" | cut -f2 | sort | uniq -d | head -n1)"
	if [ -n "$twice" ]; then
		echo "fabriek: two allowed endpoints answer as provider $twice; allow one" >&2
		return 1
	fi
	[ -z "$routed" ] || printf '%s\n' "$routed"
}

## Where a session starts: the first routed provider, on the model the
## operator named for its endpoint, else the table's. pi starts on no model
## unless told one, and a session with nobody at the keyboard cannot be
## asked; a declaration cannot name one (ADR-029). A routed endpoint with no
## model at all is refused here, by name, rather than started on nothing.
##
## fabriek_render_model <declaration.json> <models-json> <endpoints-json>
fabriek_render_model() {
	local declaration="$1" models="$2" endpoints="$3" routed host provider missing
	routed="$(fabriek_render_routed "$declaration" "$endpoints")" || return 1
	missing="$(printf '%s\n' "$routed" | cut -f1 | jq -Rr --argjson models "$models" --argjson endpoints "$endpoints" '
	  select(length > 0 and (($models[.] // $endpoints[.].model) == null))' | head -n1)"
	if [ -n "$missing" ]; then
		echo "fabriek: endpoint $missing has no model; name one under models" >&2
		return 1
	fi
	## A declaration allowing no endpoint routes nothing, and a session then
	## starts on the first shipped row.
	IFS=$'\t' read -r host provider <<<"$routed"
	[ -n "$provider" ] || {
		host="api.anthropic.com"
		provider="anthropic"
	}
	jq -cn --arg p "$provider" --arg h "$host" --argjson models "$models" --argjson endpoints "$endpoints" \
		'{ model: ($models[$h] // $endpoints[$h].model), provider: $p }
		 + (if $endpoints[$h].models then { models: $endpoints[$h].models } else {} end)'
}

## The model one role starts on (ADR-072 point 2): the name the role gives,
## else the name its specialists give, looked up among the names the start
## endpoint lists; else the endpoint's own start model. A name the endpoint
## does not list is refused by role and name, so a repository reaches no
## model the operator did not offer.
##
## fabriek_render_role_model <declaration.json> <model.json> <role> <specialist's name or empty>
fabriek_render_role_model() {
	local declaration="$1" model_file="$2" role="$3" specialist="$4" name
	name="$(jq -r --arg r "$role" '.roles[$r].model // empty' "$declaration")" || return 1
	[ -n "$name" ] || name="$specialist"
	if [ -z "$name" ]; then
		jq -r .model "$model_file"
		return
	fi
	if [ "$(jq -r '(.models // {}) | length' "$model_file")" -eq 0 ]; then
		echo "fabriek: role $role names model $name, and the endpoint lists no model names" >&2
		return 1
	fi
	jq -er --arg n "$name" '.models[$n]' "$model_file" 2>/dev/null || {
		echo "fabriek: role $role names model $name, which the endpoint does not list" >&2
		return 1
	}
}

## models.json for pi: each routed provider at its path on the proxy, with a
## placeholder key so pi considers it configured, and the api and compat the
## endpoint's row names. The credential is the proxy's to add (ADR-025).
##
## fabriek_render_models <declaration.json> <proxy host:port> <endpoints-json>
fabriek_render_models() {
	local declaration="$1" proxy="$2" endpoints="$3" routed
	routed="$(fabriek_render_routed "$declaration" "$endpoints")" || return 1
	printf '%s\n' "$routed" |
		jq -Rsc --arg proxy "$proxy" --argjson endpoints "$endpoints" '
		  split("\n") | map(select(length > 0) | split("\t"))
		  | { providers: (map(. as [$host, $provider]
		      | { key: $provider,
		          value: ({ apiKey: "fabriek", baseUrl: "http://\($proxy)/\($host)" }
		                  + ($endpoints[$host] | with_entries(select(.key == "api" or .key == "compat")))) })
		      | from_entries) }'
}

## A role's pi directory (ADR-042 point 5): the floor's extensions, the
## profile's kit by link, the guidance in front of the specialists' prompt,
## and the models. Made fresh each time so a second prepare leaves one
## directory and not a nest of links.
##
## fabriek_render_pi_dir <floor> <profile> <models-json> <out>
fabriek_render_pi_dir() {
	local floor="$1" profile="$2" models="$3" out="$4"
	local kit="$profile/share/fabriek/specialist"
	rm -rf "$out" && mkdir -p "$out" || return 1
	cp -r "$floor/extensions" "$out/extensions" || return 1
	ln -s "$kit/lsp.json" "$out/lsp.json"
	ln -s "$kit/tests.json" "$out/tests.json"
	ln -s "$kit/skills" "$out/skills"
	cat "$floor/guidance.md" "$kit/APPEND_SYSTEM.md" >"$out/APPEND_SYSTEM.md"
	printf '%s\n' "$models" >"$out/models.json"
}

## The decider's directory (ADR-034 point 1): the floor's decider loop, in
## a directory of its own so a role's session never loads it, and the same
## models.json.
##
## fabriek_render_decider_dir <floor> <models-json> <out>
fabriek_render_decider_dir() {
	local floor="$1" models="$2" out="$3"
	rm -rf "$out" && mkdir -p "$out" || return 1
	cp -r "$floor/decider/extensions" "$out/extensions" || return 1
	printf '%s\n' "$models" >"$out/models.json"
}

## The credential the machine booted with (ADR-057 point 3), as JSON. One
## file, the operator's config.toml projected for this factory plus the
## pin; read by the one TOML reader (repo-declaration.sh).
##
## fabriek_render_credential <fabriek.toml>
fabriek_render_credential() {
	local file="$1"
	if [ ! -f "$file" ]; then
		echo "fabriek: no credential at $file; the machine was started without a factory" >&2
		return 1
	fi
	fabriek_toml_json "$file"
}

## The local facts the clamp reads (machine-spec.sh), from the credential:
## the same shape the operator's host used to write beside the machine
## flake, minus the port and the key, which are the runner's now.
##
## fabriek_render_local <credential.json>
fabriek_render_local() {
	local credential="$1"
	jq -c '{ factory: .factory.name, hostSystem: .factory.hostSystem,
	         caps: (.caps // {}), credentials: (.credentials // {}), models: (.models // {}),
	         names: (.names // {}), endpoints: (.endpoints // {}) }' "$credential"
}

## The URIs a profile's evaluation may reach (ADR-057 point 6): the clone at
## the pin and every input the repository's flake locks, by the reference
## the lock records. Nothing else; with the host's store as the lower
## layer, an unrestricted evaluation could read all of it. fabriek and its
## nixpkgs are paths, granted on the search path and not here.
##
## fabriek_profile_allowed_uris <clone> <rev>
fabriek_profile_allowed_uris() {
	local clone="$1" rev="$2" lock
	## Twice: getFlake asks for the clone by its reference, fetchGit (the
	## catalogue's tree, profile.nix) with the rev and exportIgnore as a
	## query, which no prefix admits.
	printf '%s\n' "git+file://$clone" "git+file://$clone?exportIgnore=1&rev=$rev"
	## nix asks for a locked input by its reference with the narHash as a
	## query, and an allowed prefix admits a subdirectory but not a query,
	## so the entry is spelled as nix will ask for it: the hash encoded as
	## nix encodes a query value, which keeps : @ / ? beyond the unreserved
	## set and encodes + and =.
	if lock="$(git -C "$clone" show "$rev:flake.lock" 2>/dev/null)"; then
		printf '%s' "$lock" | jq -r '
		  .nodes | to_entries[] | .value.locked // empty
		  | (if .type == "github" then "github:\(.owner)/\(.repo)/\(.rev)"
		     elif .type == "gitlab" then "gitlab:\(.owner)/\(.repo)/\(.rev)"
		     elif .type == "git" then .url
		     elif .type == "tarball" then .url
		     else empty end) as $ref
		  | if .narHash then "\($ref)\(if ($ref | contains("?")) then "&" else "?" end)narHash=\(.narHash | @uri | gsub("%2F"; "/") | gsub("%3A"; ":") | gsub("%40"; "@") | gsub("%3F"; "?"))" else $ref end' | sort -u
	fi
}

## One role's profile, built by the machine's daemon from the repository at
## the pin (ADR-057 point 5, modules/profile.nix). Prints the store path, or
## nix's own refusal, which names the role and what it lacked.
##
## The operator's entries (ADR-061): declared.json is the credential's
## [specialists] and [skills]; catalogues one directory per line. Each
## path among them is a store path the host put there, granted to the
## evaluator on the search path as fabriek's own is.
##
## fabriek_profile_build <clone> <rev> <self> <nixpkgs> <system> <role> <declaration.json> [<declared.json> <catalogues>]
fabriek_profile_build() {
	local clone="$1" rev="$2" self="$3" nixpkgs="$4" system="$5" role="$6" declaration="$7" declared="${8:-}" catalogues="${9:-}"
	local specialists shell catalogue uris declared_json="{}" extra="" path
	specialists="$(jq -c --arg r "$role" '.roles[$r].specialists // []' "$declaration")"
	shell="$(jq -c --arg r "$role" '.roles[$r].shell // null' "$declaration")"
	catalogue="$(jq -c '.catalogue // null' "$declaration")"
	uris="$(fabriek_profile_allowed_uris "$clone" "$rev" | tr '\n' ' ')"
	local -a include=(-I "$self" -I "$nixpkgs")
	[ -n "$declared" ] && [ -f "$declared" ] && declared_json="$(jq -c '{specialists: (.specialists // {}), skills: (.skills // {})}' "$declared")"
	if [ -n "$catalogues" ] && [ -f "$catalogues" ]; then
		while IFS= read -r path; do
			[ -n "$path" ] || continue
			extra="$extra $(fabriek_nix_string "$path")"
			include+=(-I "$path")
		done <"$catalogues"
	fi
	while IFS= read -r path; do
		[ -n "$path" ] || continue
		include+=(-I "$path")
	done < <(printf '%s' "$declared_json" | jq -r '(.specialists[]?.prompt // empty), (.skills[]?.skill // empty) | select(startswith("/"))')
	## One line, so a record of the call is one line too. Every path is a
	## string: a path literal is copied into the store on interpolation,
	## and profile.nix interpolates fabriek's; the copy is a second fabriek
	## in the upper layer, made by reading the lower one file by file
	## (measured 2026-09-16: a copy with an empty catalogue.nix on the pc).
	local expr
	expr="import $self/modules/profile.nix {"
	expr="$expr self = $(fabriek_nix_string "$self"); nixpkgs = $(fabriek_nix_string "$nixpkgs");"
	expr="$expr clone = $(fabriek_nix_string "$clone"); rev = $(fabriek_nix_string "$rev");"
	expr="$expr system = $(fabriek_nix_string "$system"); role = $(fabriek_nix_string "$role");"
	expr="$expr specialists = builtins.fromJSON $(fabriek_nix_string "$specialists");"
	expr="$expr shell = $shell; catalogue = $catalogue;"
	expr="$expr declared = builtins.fromJSON $(fabriek_nix_string "$declared_json");"
	expr="$expr catalogues = [$extra ]; }"
	## The URIs let getFlake fetch the clone; reading fabriek, nixpkgs and
	## the operator's paths is a file access, which restricted mode grants
	## to the search path and to nothing else.
	nix build --no-link --print-out-paths --impure \
		--restrict-eval --allowed-uris "${uris% }" "${include[@]}" \
		--expr "$expr"
}
