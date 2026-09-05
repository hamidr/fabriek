#!/usr/bin/env bats
# Integration: advancing the branch the factory shares with the operator, and
# stopping when their histories no longer agree (PRD-003 phase 6).

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/names.sh
	source "$CAGEWORKS_ROOT/modules/names.sh"
	# shellcheck source=../../modules/integrate.sh
	source "$CAGEWORKS_ROOT/modules/integrate.sh"
	STATE="$TEST_TEMP_DIR/state"
	REPO="$TEST_TEMP_DIR/operator"
	CLONE="$TEST_TEMP_DIR/clone"

	git init -q -b main "$REPO"
	git -C "$REPO" config user.name operator
	git -C "$REPO" config user.email o@x
	git -C "$REPO" config commit.gpgsign false
	echo one >"$REPO/a.txt"
	git -C "$REPO" add a.txt
	git -C "$REPO" commit -qm one
	# main is checked out by nothing, as the design requires.
	git -C "$REPO" switch -q -c operator/work

	git clone -q --no-hardlinks "$REPO" "$CLONE"
	# The operator checks main out nowhere, so cloning leaves it a remote ref.
	git -C "$CLONE" branch main origin/main
	git -C "$CLONE" config user.name factory
	git -C "$CLONE" config user.email f@x
	git -C "$CLONE" config commit.gpgsign false
}

teardown() {
	teardown_temp_dir
}

commit_in_clone() { # message -> prints the new sha
	echo "$1" >>"$CLONE/a.txt"
	git -C "$CLONE" add a.txt
	git -C "$CLONE" commit -qm "$1"
	git -C "$CLONE" rev-parse HEAD
}

@test "two repositories that agree have not diverged" {
	run cageworks_integrate_diverged "$CLONE" "$REPO" main
	assert_failure
}

@test "the factory being ahead is not divergence" {
	git -C "$CLONE" switch -q -c work main
	commit_in_clone two >/dev/null
	git -C "$CLONE" branch -f main work
	run cageworks_integrate_diverged "$CLONE" "$REPO" main
	assert_failure
}

@test "the operator being ahead is not divergence" {
	git -C "$REPO" switch -q main
	echo two >>"$REPO/a.txt"
	git -C "$REPO" commit -aqm two
	git -C "$REPO" switch -q operator/work
	run cageworks_integrate_diverged "$CLONE" "$REPO" main
	assert_failure
}

@test "a rewritten history is divergence" {
	git -C "$CLONE" switch -q -c work main
	commit_in_clone two >/dev/null
	git -C "$CLONE" branch -f main work
	# The operator rewrites what the clone was built on.
	git -C "$REPO" switch -q main
	git -C "$REPO" commit -q --amend -m "one, rewritten"
	git -C "$REPO" switch -q operator/work
	run cageworks_integrate_diverged "$CLONE" "$REPO" main
	assert_success
}

@test "a halted factory says so, and says why" {
	cageworks_integrate_halt "$STATE" acme "the operator rewrote main"
	run cageworks_integrate_halted "$STATE" acme
	assert_success
	assert_output --partial "rewrote main"
}

@test "a factory nobody halted is not halted" {
	run cageworks_integrate_halted "$STATE" acme
	assert_failure
}

@test "halting one factory leaves the others running" {
	cageworks_integrate_halt "$STATE" acme "reason"
	run cageworks_integrate_halted "$STATE" other
	assert_failure
}

@test "resuming is explicit, and undoes the halt" {
	cageworks_integrate_halt "$STATE" acme "reason"
	cageworks_integrate_resume "$STATE" acme
	run cageworks_integrate_halted "$STATE" acme
	assert_failure
}

@test "advancing the shared branch to a descendant works" {
	git -C "$CLONE" switch -q -c work main
	sha="$(commit_in_clone two)"
	run cageworks_integrate_advance "$CLONE" main "$sha"
	assert_success
	[ "$(git -C "$CLONE" rev-parse main)" = "$sha" ]
}

@test "advancing to something that is not a descendant is refused" {
	git -C "$CLONE" switch -q -c work main
	commit_in_clone two >/dev/null
	git -C "$CLONE" branch -f main work
	# A commit on a branch that left main behind is not a fast-forward.
	git -C "$CLONE" switch -q -c sideways HEAD~1
	side="$(commit_in_clone sideways)"
	run cageworks_integrate_advance "$CLONE" main "$side"
	assert_failure
	assert_output --partial "fast-forward"
}

@test "the operator's checkout receives what the factory advanced" {
	git -C "$CLONE" switch -q -c work main
	sha="$(commit_in_clone two)"
	cageworks_integrate_advance "$CLONE" main "$sha"
	run cageworks_integrate_publish "$CLONE" "$REPO" main
	assert_success
	[ "$(git -C "$REPO" rev-parse main)" = "$sha" ]
}

@test "publishing never rewrites the operator's history" {
	git -C "$CLONE" switch -q -c work main
	commit_in_clone two >/dev/null
	git -C "$CLONE" branch -f main work
	git -C "$REPO" switch -q main
	git -C "$REPO" commit -q --amend -m "one, rewritten"
	git -C "$REPO" switch -q operator/work
	run cageworks_integrate_publish "$CLONE" "$REPO" main
	assert_failure
}
