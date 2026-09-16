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
## cannot disagree.
##
## fabriek_render_bridge_plan <declaration.json> <bridge> <proxyPort> <forgejoPort> <valkeyPort>
fabriek_render_bridge_plan() {
	local declaration="$1" bridge="$2" proxy_port="$3" forgejo_port="$4" valkey_port="$5"
	## -S: keys in name order, as the build's toJSON wrote them, so the set
	## below and the executor's reading of the plan meet what they met.
	jq -cS --arg bridge "$bridge" --arg proxy "$proxy_port" --arg forgejo "$forgejo_port" --arg valkey "$valkey_port" '
	  "10.77.0" as $net
	  | (.roles | keys) as $roles
	  | { bridge: $bridge,
	      host: "\($net).1",
	      prefix: 24,
	      cages: ({ decider: "\($net).2" }
	        + ([$roles | to_entries[] | { key: .value, value: "\($net).\(10 + .key)" }] | from_entries)),
	      proxy: "\($net).1:\($proxy)",
	      forgejo: "\($net).1:\($forgejo)",
	      valkey: "\($net).1:\($valkey)" }' "$declaration"
}

## The elements of the bridge's cages set: the veth nixcage will name for
## the cage (nixcage ADR-013) beside the address the plan gives it, in the
## form nft takes. Asked of nixcage rather than computed, because the name
## is nixcage's function.
##
## fabriek_render_cage_elements <plan.json>
fabriek_render_cage_elements() {
	local plan="$1" name address veth parts=()
	while IFS=$'\t' read -r name address; do
		veth="$(nixcage-container veth "$name")" || return 1
		parts+=("\"$veth\" . $address")
	done < <(jq -r '.cages | to_entries[] | "\(.key)\t\(.value)"' "$plan")
	local joined="" part
	for part in "${parts[@]}"; do
		joined="${joined:+$joined, }$part"
	done
	printf '%s\n' "$joined"
}

## The proxy's configuration for one factory: the token ceiling and a
## location per allowed endpoint, each counting what passes and refusing at
## the ceiling. Included by the vhost the image carries. Zero is no ceiling.
##
## fabriek_render_proxy <declaration.json>
fabriek_render_proxy() {
	local declaration="$1" host
	printf "set \$spend_ceiling %s;\n" "$(jq -r '.resources.tokens // 0' "$declaration")"
	while IFS= read -r host; do
		[ -n "$host" ] || continue
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
  js_body_filter spend.count;
  include /run/fabriek-egress/$host.conf;
}
CONF
	done < <(jq -r '.resources.egress // [] | .[]' "$declaration")
}

## Which of pi's built-in providers answers at which endpoint, and the model
## each starts on when the operator names none. Only the endpoints fabriek
## knows; one outside this table is reachable through the proxy but pi is
## not pointed at it.
FABRIEK_PROVIDERS='{"api.anthropic.com":"anthropic","api.openai.com":"openai","api.deepseek.com":"deepseek"}'
FABRIEK_DEFAULT_MODELS='{"anthropic":"claude-sonnet-4-5","openai":"gpt-5","deepseek":"deepseek-v4-flash"}'

## The endpoints the declaration allows that pi has a provider for, in the
## table's order. Prints "host<TAB>provider" lines.
fabriek_render_routed() {
	local declaration="$1"
	jq -r --argjson providers "$FABRIEK_PROVIDERS" '
	  (.resources.egress // []) as $allowed
	  | $providers | to_entries[] | select(.key as $h | $allowed | index($h) != null)
	  | "\(.key)\t\(.value)"' "$declaration"
}

## Where a session starts: the first routed provider, on the model the
## operator named for its endpoint, else fabriek's default. pi starts on no
## model unless told one, and a session with nobody at the keyboard cannot
## be asked; a declaration cannot name one (ADR-029).
##
## fabriek_render_model <declaration.json> <models-json>
fabriek_render_model() {
	local declaration="$1" models="$2" host provider
	IFS=$'\t' read -r host provider < <(fabriek_render_routed "$declaration")
	[ -n "$provider" ] || {
		host="api.anthropic.com"
		provider="anthropic"
	}
	jq -cn --arg p "$provider" --arg h "$host" --argjson models "$models" --argjson defaults "$FABRIEK_DEFAULT_MODELS" \
		'{ model: ($models[$h] // $defaults[$p]), provider: $p }'
}

## models.json for pi: each routed provider at its path on the proxy, with a
## placeholder key so pi considers it configured. The credential is the
## proxy's to add (ADR-025).
##
## fabriek_render_models <declaration.json> <proxy host:port>
fabriek_render_models() {
	local declaration="$1" proxy="$2"
	fabriek_render_routed "$declaration" |
		jq -Rsc --arg proxy "$proxy" '
		  split("\n") | map(select(length > 0) | split("\t"))
		  | { providers: (map({ key: .[1], value: { apiKey: "fabriek", baseUrl: "http://\($proxy)/\(.[0])" } }) | from_entries) }'
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
	         caps: (.caps // {}), credentials: (.credentials // {}), models: (.models // {}) }' "$credential"
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
	printf '%s\n' "git+file://$clone"
	## nix asks for a locked input by its reference with the narHash as a
	## query, and an allowed prefix admits a subdirectory but not a query,
	## so the entry is spelled as nix will ask for it.
	if lock="$(git -C "$clone" show "$rev:flake.lock" 2>/dev/null)"; then
		printf '%s' "$lock" | jq -r '
		  .nodes | to_entries[] | .value.locked // empty
		  | (if .type == "github" then "github:\(.owner)/\(.repo)/\(.rev)"
		     elif .type == "gitlab" then "gitlab:\(.owner)/\(.repo)/\(.rev)"
		     elif .type == "git" then .url
		     elif .type == "tarball" then .url
		     else empty end) as $ref
		  | if .narHash then "\($ref)\(if ($ref | contains("?")) then "&" else "?" end)narHash=\(.narHash | @uri)" else $ref end' | sort -u
	fi
}

## One role's profile, built by the machine's daemon from the repository at
## the pin (ADR-057 point 5, modules/profile.nix). Prints the store path, or
## nix's own refusal, which names the role and what it lacked.
##
## fabriek_profile_build <clone> <rev> <self> <nixpkgs> <system> <role> <declaration.json>
fabriek_profile_build() {
	local clone="$1" rev="$2" self="$3" nixpkgs="$4" system="$5" role="$6" declaration="$7"
	local specialists shell catalogue uris
	specialists="$(jq -c --arg r "$role" '.roles[$r].specialists // []' "$declaration")"
	shell="$(jq -c --arg r "$role" '.roles[$r].shell // null' "$declaration")"
	catalogue="$(jq -c '.catalogue // null' "$declaration")"
	uris="$(fabriek_profile_allowed_uris "$clone" "$rev" | tr '\n' ' ')"
	## One line, so a record of the call is one line too.
	local expr
	expr="import $self/modules/profile.nix {"
	expr="$expr self = $self; nixpkgs = $nixpkgs;"
	expr="$expr clone = $(fabriek_nix_string "$clone"); rev = $(fabriek_nix_string "$rev");"
	expr="$expr system = $(fabriek_nix_string "$system"); role = $(fabriek_nix_string "$role");"
	expr="$expr specialists = builtins.fromJSON $(fabriek_nix_string "$specialists");"
	expr="$expr shell = $shell; catalogue = $catalogue; }"
	## The URIs let getFlake fetch the clone; reading fabriek and nixpkgs
	## by path is a file access, which restricted mode grants to the search
	## path and to nothing else.
	nix build --no-link --print-out-paths --impure \
		--restrict-eval --allowed-uris "${uris% }" -I "$self" -I "$nixpkgs" \
		--expr "$expr"
}
