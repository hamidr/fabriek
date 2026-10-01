#!/usr/bin/env bats
# What of a repository's lockfile the host will fetch for a factory's
# dependency cache (ADR-046 points 1b and 1e): an artifact named with its
# integrity on an allowed registry, and nothing else.

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/dependency-cache.sh
	source "$FABRIEK_ROOT/modules/dependency-cache.sh"
	LOCK="$TEST_TEMP_DIR/package-lock.json"
}

teardown() {
	teardown_temp_dir
}

lock() {
	jq -n --argjson packages "$1" '{name: "app", lockfileVersion: 3, packages: ({"": {name: "app"}} + $packages)}' >"$LOCK"
}

registry() {
	printf '{"resolved": "https://registry.npmjs.org/%s/-/%s-1.0.0.tgz", "integrity": "sha512-AAAA"}' "$1" "$1"
}

@test "a lockfile whose every artifact is on the npm registry with its integrity is refused nothing" {
	lock "{\"node_modules/left-pad\": $(registry left-pad), \"node_modules/tiny\": $(registry tiny)}"
	run fabriek_npm_lock_refused "$LOCK"
	assert_success
	assert_output ""
}

# A fixed-output hash checks what came back, not where the request went:
# the host would send this request, data and all, before any hash is
# compared.
@test "an artifact on any other host is refused by its package and host, so the host never asks it" {
	lock "{\"node_modules/tiny\": $(registry tiny), \"node_modules/leak\": {\"resolved\": \"https://attacker.example/c2VjcmV0.tgz\", \"integrity\": \"sha512-AAAA\"}}"
	run fabriek_npm_lock_refused "$LOCK"
	assert_failure
	assert_output "node_modules/leak: attacker.example is not an allowed registry"
}

@test "a registry named over plain http, or by a lookalike host, is refused" {
	lock '{"node_modules/a": {"resolved": "http://registry.npmjs.org/a/-/a-1.0.0.tgz", "integrity": "sha512-AAAA"}, "node_modules/b": {"resolved": "https://registry.npmjs.org.attacker.example/b.tgz", "integrity": "sha512-AAAA"}}'
	run fabriek_npm_lock_refused "$LOCK"
	assert_failure
	assert_line "node_modules/a: http://registry.npmjs.org is not an allowed registry"
	assert_line "node_modules/b: registry.npmjs.org.attacker.example is not an allowed registry"
}

@test "an artifact with no integrity is refused, since its fetch could not be checked" {
	lock '{"node_modules/a": {"resolved": "https://registry.npmjs.org/a/-/a-1.0.0.tgz"}}'
	run fabriek_npm_lock_refused "$LOCK"
	assert_failure
	assert_output "node_modules/a: no integrity"
}

@test "a package the repository links to itself is not an artifact and is passed over" {
	lock '{"node_modules/local": {"resolved": "packages/local", "link": true}, "packages/local": {"name": "local"}}'
	run fabriek_npm_lock_refused "$LOCK"
	assert_success
	assert_output ""
}

@test "a version 1 lockfile, which names its artifacts elsewhere, is refused as a whole" {
	jq -n '{name: "app", lockfileVersion: 1, dependencies: {}}' >"$LOCK"
	run fabriek_npm_lock_refused "$LOCK"
	assert_failure
	assert_output "package-lock.json: lockfileVersion 1 is not read; npm 7 and later write 2 or 3"
}

@test "the artifacts fetched are each named once, by url and integrity, however many packages share one" {
	lock "{\"node_modules/tiny\": $(registry tiny), \"node_modules/a/node_modules/tiny\": $(registry tiny), \"node_modules/left-pad\": $(registry left-pad)}"
	run fabriek_npm_lock_artifacts "$LOCK"
	assert_success
	assert_output '[{"url":"https://registry.npmjs.org/left-pad/-/left-pad-1.0.0.tgz","integrity":"sha512-AAAA"},{"url":"https://registry.npmjs.org/tiny/-/tiny-1.0.0.tgz","integrity":"sha512-AAAA"}]'
}
