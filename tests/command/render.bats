#!/usr/bin/env bats
# What factory-render does at boot from the credential the machine was
# handed (ADR-057 points 3 to 5, 7): reads fabriek.toml, fetches the
# repository at the pin, reads its declaration, clamps it against the caps,
# writes what the services include under the state directory, fills the
# bridge's set, builds a profile per role with the machine's daemon and
# composes its pi directory, and writes
# profiles.json. Then the services that include any of it are reloaded.
#
# nix build, systemctl and nixcage-container are stubbed; nix eval is
# the real one, since the TOML reader and the declaration's schema are what
# is under test too.

load ../test_helper/common
load ../test_helper/stubs

setup() {
	setup_temp_dir
	STATE="$TEST_TEMP_DIR/state"
	STUB_DIR="$TEST_TEMP_DIR/bin"
	ETC="$TEST_TEMP_DIR/etc"
	RUN="$TEST_TEMP_DIR/run"
	CALLS="$TEST_TEMP_DIR/calls"
	mkdir -p "$STATE" "$STUB_DIR" "$RUN" "$CALLS"
	REAL_NIX="$(command -v nix)"
	PATH="$STUB_DIR:$PATH"
	export PATH STATE
	export FABRIEK_STATE="$STATE" FABRIEK_ETC="$ETC" FABRIEK_RUN="$RUN" FABRIEK_FACTORY=acme
	export FABRIEK_BRIDGE=fabriek0 FABRIEK_BRIDGE_HOST=10.77.0.1 FABRIEK_PROXY_PORT=8118 \
		FABRIEK_FORGEJO_PORT=3000 FABRIEK_BUS_PORT=4222
	export FABRIEK_FLOOR="$TEST_TEMP_DIR/floor" FABRIEK_SELF="$TEST_TEMP_DIR/self" FABRIEK_NIXPKGS="$TEST_TEMP_DIR/nixpkgs" FABRIEK_SYSTEM=aarch64-linux
	mkdir -p "$FABRIEK_FLOOR/extensions/fabriek" "$FABRIEK_FLOOR/decider/extensions/fabriek" "$FABRIEK_SELF"
	echo loop >"$FABRIEK_FLOOR/extensions/fabriek/index.ts"
	echo decider >"$FABRIEK_FLOOR/decider/extensions/fabriek/index.ts"
	echo '# Working as a factory role' >"$FABRIEK_FLOOR/guidance.md"

	# The repository the factory works, with its declaration committed, and
	# an origin the machine clones from.
	REPO="$TEST_TEMP_DIR/origin"
	mkdir -p "$REPO/docs"
	git init -q -b main "$REPO"
	git -C "$REPO" config user.name factory
	git -C "$REPO" config user.email factory@invalid
	cat >"$REPO/fabriek.toml" <<'TOML'
name = "acme"

[roles.builder]
provides = ["build"]
specialists = ["python"]
shell = "backend"

[roles.reviewer]
provides = ["review"]

[[workflows.ship.stages]]
needs = "build"

[[workflows.ship.stages]]
needs = "review"

[resources]
memory = "4G"
cores = 2
tokens = 500000
egress = ["api.anthropic.com", "api.openai.com"]

[decider]
policy = "docs/policy.md"
TOML
	echo "Prefer finishing started work." >"$REPO/docs/policy.md"
	printf '{ outputs = { self }: { }; }\n' >"$REPO/flake.nix"
	git -C "$REPO" add -A
	git -C "$REPO" -c commit.gpgsign=false commit -qm declare
	REV="$(git -C "$REPO" rev-parse HEAD)"

	# The credential the machine booted with (ADR-057 point 3).
	CRED="$TEST_TEMP_DIR/fabriek.toml"
	cat >"$CRED" <<TOML
[factory]
name = "acme"
hostSystem = "aarch64-darwin"

[repository]
path = "$REPO"
remote = "$REPO"

[pin]
rev = "$REV"

[caps]
memory = "16G"
cores = 8
tokens = 1000000
egress = ["api.anthropic.com"]

[credentials]
"api.anthropic.com" = "x-api-key"

[models]
"api.anthropic.com" = "claude-opus-5"

[embedder]
url = "http://10.0.2.2:8080"
TOML
	export FABRIEK_CREDENTIAL="$CRED"

	stub_nix_build "$CALLS" "$REAL_NIX" "$TEST_TEMP_DIR/store"
	cat >"$STUB_DIR/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$CALLS/systemctl"
EOF
	## No nft: the bridge's rules are nixcage's (ADR-064), so a prepare that
	## reached for it would fail here on a command that does not exist.
	cat >"$STUB_DIR/nixcage-container" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$CALLS/nixcage-container"
case "\$1" in
storage) echo "$STATE/forgejo" ;;
esac
EOF
	cat >"$STUB_DIR/id" <<'EOF'
#!/usr/bin/env bash
echo 993
EOF
	chmod +x "$STUB_DIR"/*
}

teardown() {
	teardown_temp_dir
}

@test "render reads the credential, fetches the pin and writes the clamped declaration for the machine program" {
	run_fabriek_container factory-render
	assert_success
	[ -f "$ETC/declaration.json" ]
	run jq -c '[.name, (.roles | keys), .resources.cores, .resources.egress]' "$ETC/declaration.json"
	assert_output '["acme",["builder","reviewer"],2,["api.anthropic.com"]]'
	run cat "$ETC/rev"
	assert_output "$REV"
}

@test "what the clamp changed is said, and kept for up to print" {
	run_fabriek_container factory-render
	assert_success
	assert_output --partial "egress asked for api.openai.com, which this host does not allow; dropped"
	run jq -r '.[]' "$ETC/notes.json"
	assert_output --partial "api.openai.com"
}

@test "the bridge plan is written for the executor and the session composer, and feeds no ruleset" {
	run_fabriek_container factory-render
	assert_success
	run jq -c '[.bridge, .cages]' "$ETC/bridge.json"
	assert_output '["fabriek0",{"builder":"10.77.0.10","decider":"10.77.0.2","reviewer":"10.77.0.11"}]'
	[ ! -e "$CALLS/nft" ]
	run grep veth "$CALLS/nixcage-container"
	assert_failure
}

# The facts the host wrote name the bridge and its address (ADR-067 point
# 3); a second factory's plan is on its own net and not the first's.
@test "the bridge plan is laid on the net of the bridge the facts name" {
	FABRIEK_BRIDGE=fb-1 FABRIEK_BRIDGE_HOST=10.77.1.1 run_fabriek_container factory-render
	assert_success
	run jq -c '[.bridge, .host, .cages.decider, .bus]' "$ETC/bridge.json"
	assert_output '["fb-1","10.77.1.1","10.77.1.2","10.77.1.1:4222"]'
}

@test "the proxy's ceiling and locations, the endpoints and the model are written, and nginx reloaded after the headers" {
	run_fabriek_container factory-render
	assert_success
	run cat "$ETC/proxy/endpoints.conf"
	assert_line --index 0 'set $spend_ceiling 500000;'
	assert_output --partial 'location /api.anthropic.com/ {'
	refute_output --partial 'api.openai.com'
	run jq -c . "$ETC/endpoints.json"
	assert_output '{"credentials":{"api.anthropic.com":"x-api-key"},"embedder":"http://10.0.2.2:8080","models":{"api.anthropic.com":"claude-opus-5"}}'
	run cat "$ETC/model.json"
	assert_output '{"model":"claude-opus-5","provider":"anthropic"}'
	run cat "$CALLS/systemctl"
	assert_line --partial 'restart fabriek-acme-egress-credentials'
	assert_line --partial 'reload nginx'
}

@test "the decider's policy is read from the pin and its directory composed from the floor" {
	run_fabriek_container factory-render
	assert_success
	run cat "$ETC/decider-policy.md"
	assert_output "Prefer finishing started work."
	run cat "$ETC/pi-decider/extensions/fabriek/index.ts"
	assert_output decider
	[ -f "$ETC/pi-decider/models.json" ]
}

# ADR-057 point 5: the machine's daemon builds each role's profile from the
# repository at the pin, restricted to the clone, fabriek and the flake's
# locked inputs, and the session finds it linked beside the pi directory.
@test "a profile per role is built by the daemon at the pin, restricted, and linked with a pi directory beside it" {
	run_fabriek_container factory-render
	assert_success
	run cat "$CALLS/nix-build"
	assert_line --index 0 --partial '--restrict-eval'
	assert_line --index 0 --partial "--allowed-uris git+file://$STATE/factories/acme git+file://$STATE/factories/acme?exportIgnore=1&rev=$REV "
	# fabriek and its nixpkgs are read by path, which restricted mode grants
	# to the search path and nothing else; neither is a URI, so nothing of
	# fabriek's own lock is fetched on the machine (measured 2026-09-16).
	assert_line --index 0 --partial "-I $FABRIEK_SELF -I $FABRIEK_NIXPKGS "
	# As strings, not path literals: a path literal interpolated in
	# profile.nix would copy fabriek into the machine's store.
	assert_line --index 0 --partial "self = \"$FABRIEK_SELF\"; nixpkgs = \"$FABRIEK_NIXPKGS\";"
	refute_line --index 0 --partial "getFlake"
	assert_line --index 0 --partial "rev = \"$REV\""
	assert_line --index 0 --partial 'role = "builder"'
	assert_line --index 0 --partial 'shell = "backend"'
	assert_line --index 1 --partial 'role = "reviewer"'
	assert_line --index 1 --partial 'shell = null'
	[ "$(readlink "$ETC/roles/builder/profile")" = "$TEST_TEMP_DIR/store/fabriek-role-builder" ]
	[ "$(readlink "$ETC/roles/reviewer/profile")" = "$TEST_TEMP_DIR/store/fabriek-role-reviewer" ]
	run cat "$ETC/roles/builder/pi/APPEND_SYSTEM.md"
	assert_line --index 0 '# Working as a factory role'
	assert_line --index 1 '## builder'
	# A role that names no model starts on the endpoint's own (ADR-072).
	[ "$(cat "$ETC/roles/builder/model")" = "claude-opus-5" ]
	[ "$(cat "$ETC/roles/reviewer/model")" = "claude-opus-5" ]
	run jq -c '[.rev, .roles, .decider]' "$ETC/profiles.json"
	assert_output "[\"$REV\",{\"builder\":\"$TEST_TEMP_DIR/store/fabriek-role-builder\",\"reviewer\":\"$TEST_TEMP_DIR/store/fabriek-role-reviewer\"},\"$ETC/pi-decider\"]"
}

## A package-lock.json at the pin, committed to the repository the factory
## works. Each argument is an entry of its packages as JSON.
commit_lock() {
	jq -n --argjson packages "$1" '{name: "app", lockfileVersion: 3, packages: ({"": {name: "app"}} + $packages)}' >"$REPO/package-lock.json"
	git -C "$REPO" add package-lock.json
	git -C "$REPO" -c commit.gpgsign=false commit -qm lock
	REV="$(git -C "$REPO" rev-parse HEAD)"
	sed -i "s/^rev = .*/rev = \"$REV\"/" "$CRED"
}

# ADR-046: the commit's npm artifacts, fetched on the host at render from
# an allowed registry and laid out once for every role to resolve from.
@test "given a package-lock.json at the pin, render builds one npm cache from its artifacts and links it for the sessions" {
	commit_lock '{"node_modules/tiny": {"resolved": "https://registry.npmjs.org/tiny/-/tiny-1.0.0.tgz", "integrity": "sha512-AAAA"}}'
	run_fabriek_container factory-render
	assert_success
	run grep -c 'npm-cache.nix' "$CALLS/nix-build"
	assert_output 1
	run grep 'npm-cache.nix' "$CALLS/nix-build"
	assert_output --partial '--restrict-eval'
	assert_output --partial 'https://registry.npmjs.org/tiny/-/tiny-1.0.0.tgz'
	assert_output --partial 'sha512-AAAA'
	[ "$(readlink "$ETC/cache/npm")" = "$TEST_TEMP_DIR/store/fabriek-npm-cache" ]
}

# A fixed-output hash checks what came back, not where the request went.
@test "a lockfile naming a host off the allowlist stops render by entry, and nothing of it is built" {
	commit_lock '{"node_modules/leak": {"resolved": "https://attacker.example/c2VjcmV0.tgz", "integrity": "sha512-AAAA"}}'
	run_fabriek_container factory-render
	assert_failure
	assert_output --partial "node_modules/leak: attacker.example is not an allowed registry"
	run grep -c 'npm-cache.nix' "$CALLS/nix-build"
	assert_output 0
	[ ! -e "$ETC/cache/npm" ]
}

@test "a repository with no package-lock.json at the pin has no npm cache, and one an earlier pin left is unlinked" {
	mkdir -p "$ETC/cache"
	ln -s "$TEST_TEMP_DIR/store/stale" "$ETC/cache/npm"
	run_fabriek_container factory-render
	assert_success
	run grep -c 'npm-cache.nix' "$CALLS/nix-build"
	assert_output 0
	[ ! -L "$ETC/cache/npm" ]
}

@test "a role whose profile does not build is refused by name, and no session can start on it" {
	touch "$CALLS/fail-builder"
	run_fabriek_container factory-render
	assert_failure
	assert_output --partial "role builder names devShell backend"
	[ ! -e "$ETC/roles/builder/profile" ]
	[ ! -e "$ETC/profiles.json" ]
}

@test "a second render changes nothing and builds again what the store already has" {
	run_fabriek_container factory-render
	assert_success
	local before
	before="$(find "$ETC" -type f -exec md5sum {} + | sort)"
	run_fabriek_container factory-render
	assert_success
	[ "$(find "$ETC" -type f -exec md5sum {} + | sort)" = "$before" ]
	[ "$(wc -l <"$CALLS/nix-build")" = 4 ]
}

# ADR-057 point 6: what the repository's lock names may be fetched. nix
# asks for a locked input by its reference with the narHash appended, and
# an allowed prefix admits a subdirectory but not a query, so the lock's
# entry is allowed as nix will spell it (measured 2026-09-16: "access to
# URI 'github:...?narHash=...' is forbidden in restricted mode").
@test "the repository's locked inputs are allowed as nix asks for them, narHash and all" {
	cat >"$REPO/flake.lock" <<'JSON'
{ "nodes": {
    "parts": { "locked": { "type": "github", "owner": "hercules-ci", "repo": "flake-parts",
      "rev": "31729ca8cbdb4fa927b34e5f4353e6a83f39e993", "narHash": "sha256-glZLQlzIn1fXH6PazR2iUmTo7kzzyYSshrWhLS9TqCU=" } },
    "pkgs": { "locked": { "type": "git", "url": "https://example.invalid/pkgs.git",
      "rev": "aaaa", "narHash": "sha256-AA/A+A=" } },
    "root": { "inputs": { "parts": "parts", "pkgs": "pkgs" } } },
  "root": "root", "version": 7 }
JSON
	git -C "$REPO" add flake.lock
	git -C "$REPO" -c commit.gpgsign=false commit -qm lock
	sed -i.bak "s/rev = \".*\"/rev = \"$(git -C "$REPO" rev-parse HEAD)\"/" "$CRED" && rm "$CRED.bak"
	run_fabriek_container factory-render
	assert_success
	run cat "$CALLS/nix-build"
	assert_line --index 0 --partial "--allowed-uris git+file://$STATE/factories/acme git+file://$STATE/factories/acme?exportIgnore=1&rev=$(git -C "$REPO" rev-parse HEAD) github:hercules-ci/flake-parts/31729ca8cbdb4fa927b34e5f4353e6a83f39e993?narHash=sha256-glZLQlzIn1fXH6PazR2iUmTo7kzzyYSshrWhLS9TqCU%3D https://example.invalid/pkgs.git?narHash=sha256-AA/A%2BA%3D "
}

# ADR-061 point 6: a factory declared in the operator's file arrives in
# the credential, and render reads it there instead of the clone's file;
# the operator's specialists, skills and catalogue directories reach the
# profile build as JSON and as paths the evaluator may read.
@test "render takes the declaration from the credential when it carries one, and the clone's file is not read" {
	git -C "$REPO" rm -q fabriek.toml
	git -C "$REPO" -c commit.gpgsign=false commit -qm undeclare
	sed -i.bak "s/rev = \".*\"/rev = \"$(git -C "$REPO" rev-parse HEAD)\"/" "$CRED" && rm "$CRED.bak"
	sed -i.bak '1i catalogues = ["/nix/store/cccc-catalogue"]' "$CRED" && rm "$CRED.bak"
	cat >>"$CRED" <<'TOML'

[declaration]
"name" = "acme"

[declaration."roles"."builder"]
"provides" = ["build"]
"specialists" = ["strict"]

[[declaration."workflows"."ship"."stages"]]
"needs" = "build"

[specialists."strict"]
"extends" = ["reviewer"]
"tools" = ["semgrep"]
"prompt" = "/nix/store/pppp-strict.md"

[skills."profile"]
"skill" = "text"
TOML
	run_fabriek_container factory-render
	assert_success
	run jq -c '.roles | keys' "$ETC/declaration.json"
	assert_output '["builder"]'
	run cat "$CALLS/nix-build"
	assert_line --index 0 --partial 'role = "builder"'
	assert_line --index 0 --partial 'declared = builtins.fromJSON "{\"specialists\":{\"strict\":{\"extends\":[\"reviewer\"],\"prompt\":\"/nix/store/pppp-strict.md\",\"tools\":[\"semgrep\"]}},\"skills\":{\"profile\":{\"skill\":\"text\"}}}"'
	assert_line --index 0 --partial 'catalogues = [ "/nix/store/cccc-catalogue" ]'
	assert_line --index 0 --partial "-I /nix/store/cccc-catalogue -I /nix/store/pppp-strict.md "
}

@test "a credential carrying no declaration renders the clone's file, with no operator entries on the build line" {
	run_fabriek_container factory-render
	assert_success
	run cat "$CALLS/nix-build"
	assert_line --index 0 --partial 'declared = builtins.fromJSON "{\"specialists\":{},\"skills\":{}}"'
	assert_line --index 0 --partial 'catalogues = [ ]'
}

@test "a declaration the schema refuses stops render naming the key, before anything is written" {
	echo 'colour = "blue"' >>"$REPO/fabriek.toml"
	git -C "$REPO" -c commit.gpgsign=false commit -qam colour
	sed -i.bak "s/rev = \".*\"/rev = \"$(git -C "$REPO" rev-parse HEAD)\"/" "$CRED" && rm "$CRED.bak"
	run_fabriek_container factory-render
	assert_failure
	assert_output --partial colour
	[ ! -e "$ETC/declaration.json" ]
}

@test "without the credential, render says so and does nothing" {
	rm "$CRED"
	run_fabriek_container factory-render
	assert_failure
	assert_output --partial "no credential at $CRED"
	[ ! -e "$ETC/declaration.json" ]
}
