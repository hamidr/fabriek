#!/usr/bin/env bats
# The npm cache a factory's roles resolve from (ADR-046 point 1d), built
# for real: modules/npm-cache.nix fetches each artifact by its integrity and
# lays them out as npm's own cache, and npm installs from it offline,
# read-only, out of the store. The artifact is a local tarball served on
# the loopback, which a fixed-output fetch reaches as it would a registry,
# so the build needs no network off the host; which hosts render may name
# is dependency_cache.bats's.

load ../test_helper/common

setup() {
	setup_temp_dir
	PKG="$TEST_TEMP_DIR/pkg"
	APP="$TEST_TEMP_DIR/app"
	mkdir -p "$PKG" "$APP"
	printf '{"name":"tiny","version":"1.0.0"}' >"$PKG/package.json"
	echo 'module.exports = 1' >"$PKG/index.js"
	(cd "$PKG" && npm pack --silent >/dev/null)
	TGZ="$PKG/tiny-1.0.0.tgz"
	INTEGRITY="sha512-$(openssl dgst -sha512 -binary "$TGZ" | base64 -w0)"
	node -e 'const h=require("http"),f=require("fs");const s=h.createServer((q,r)=>{f.createReadStream(process.argv[1]).pipe(r)}).listen(0,"127.0.0.1",()=>{f.writeFileSync(process.argv[2],String(s.address().port))})' "$TGZ" "$TEST_TEMP_DIR/port" &
	SERVER=$!
	for _ in $(seq 50); do [ -s "$TEST_TEMP_DIR/port" ] && break; sleep 0.1; done
	URL="http://127.0.0.1:$(cat "$TEST_TEMP_DIR/port")/tiny-1.0.0.tgz"
	# The app's lockfile names the registry, as a real one does; npm finds
	# the tarball in the cache by its integrity and never asks the registry.
	printf '{"name":"app","version":"1.0.0","dependencies":{"tiny":"1.0.0"}}' >"$APP/package.json"
	jq -n --arg integrity "$INTEGRITY" '{name: "app", version: "1.0.0", lockfileVersion: 3, requires: true,
		packages: {"": {name: "app", version: "1.0.0", dependencies: {tiny: "1.0.0"}},
			"node_modules/tiny": {version: "1.0.0", resolved: "https://registry.npmjs.org/tiny/-/tiny-1.0.0.tgz", integrity: $integrity}}}' \
		>"$APP/package-lock.json"
}

teardown() {
	kill "$SERVER" 2>/dev/null
	chmod -R u+w "$TEST_TEMP_DIR" 2>/dev/null
	teardown_temp_dir
}

build_cache() {
	local artifacts="$1"
	nix build --no-link --print-out-paths --impure --expr "
	  let flake = builtins.getFlake \"path:$FABRIEK_ROOT\";
	  in import $FABRIEK_ROOT/modules/npm-cache.nix {
	    nixpkgs = flake.inputs.nixpkgs.outPath;
	    system = builtins.currentSystem;
	    artifacts = builtins.fromJSON ''$artifacts'';
	  }"
}

@test "given a lockfile's artifacts, the cache built from them installs the app offline, read-only out of the store" {
	run build_cache "[{\"url\":\"$URL\",\"integrity\":\"$INTEGRITY\"}]"
	assert_success
	cache="${lines[-1]}"
	[[ "$cache" == /nix/store/* ]]
	cd "$APP"
	run npm ci --offline --cache "$cache" --logs-dir "$TEST_TEMP_DIR/logs" --no-audit --no-fund
	assert_success
	[ -f "$APP/node_modules/tiny/index.js" ]
}

@test "an artifact whose content does not match its integrity fails the build, and nothing is cached" {
	run build_cache "[{\"url\":\"$URL\",\"integrity\":\"sha512-$(printf 'x%.0s' {1..86})==\"}]"
	assert_failure
	assert_output --partial "hash mismatch in fixed-output derivation"
}
