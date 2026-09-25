#!/usr/bin/env bats
# The one clone a factory works, which role worktrees are taken from (ADR-011).

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/names.sh
	source "$FABRIEK_ROOT/modules/names.sh"
	# shellcheck source=../../modules/factory-clone.sh
	source "$FABRIEK_ROOT/modules/factory-clone.sh"
	STATE="$TEST_TEMP_DIR/state"
}

teardown() {
	teardown_temp_dir
}

@test "a factory's clone lives in nixcage state, beside nothing the operator edits" {
	run fabriek_factory_clone_path "$STATE" acme
	assert_success
	assert_output "$STATE/factories/acme"
}

@test "two factories do not share a clone" {
	a="$(fabriek_factory_clone_path "$STATE" acme)"
	b="$(fabriek_factory_clone_path "$STATE" other)"
	[ "$a" != "$b" ]
}

@test "a factory name that could escape the state directory is refused" {
	run fabriek_factory_clone_path "$STATE" "../../etc"
	assert_failure
}

# ADR-067 point 5: the source is the operator's checkout on this host, and
# git's local clone hardlinks its objects; --no-hardlinks would copy them
# and --shared would borrow them, and neither is asked for.
@test "the clone is a local clone of the checkout, objects hardlinked and nothing borrowed" {
	run fabriek_factory_clone_args /srv/acme "$STATE/factories/acme"
	assert_success
	refute_output --partial "--no-hardlinks"
	refute_output --partial "--shared"
	assert_line --index 0 "/srv/acme"
	assert_line --index 1 "$STATE/factories/acme"
}

@test "the clone's own tree sits on a branch no role could ever hold" {
	run fabriek_factory_clone_branch
	assert_success
	# A role's branches are always <role>/<leaf>, so a single segment cannot collide.
	refute_output --partial "/"
}

@test "main is not what the clone has checked out" {
	run fabriek_factory_clone_branch
	refute_output "main"
	refute_output "master"
}

@test "git is told the operator's checkout is trustworthy, since the supervisor does not own it" {
	run fabriek_factory_git_args /srv/acme
	assert_success
	assert_line "safe.directory=/srv/acme"
	assert_line "safe.directory=/srv/acme/*"
}

@test "the clone has the shared branch locally, since the operator checks it out nowhere" {
	origin="$TEST_TEMP_DIR/origin"
	git init -q -b main "$origin"
	git -C "$origin" config user.name o
	git -C "$origin" config user.email o@x
	git -C "$origin" config commit.gpgsign false
	echo x >"$origin/a.txt"
	git -C "$origin" add a.txt
	git -C "$origin" commit -qm one
	# main checked out by nothing, exactly as the design requires.
	git -C "$origin" switch -q -c operator/work

	path="$(fabriek_factory_clone_ensure "$STATE" acme "$origin")"
	run git -C "$path" rev-parse --verify refs/heads/main
	assert_success
}

@test "the clone's own tree is not on the branch it integrates" {
	origin="$TEST_TEMP_DIR/origin2"
	git init -q -b main "$origin"
	git -C "$origin" config user.name o
	git -C "$origin" config user.email o@x
	git -C "$origin" config commit.gpgsign false
	echo x >"$origin/a.txt"
	git -C "$origin" add a.txt
	git -C "$origin" commit -qm one
	git -C "$origin" switch -q -c operator/work

	path="$(fabriek_factory_clone_ensure "$STATE" acme2 "$origin")"
	[ "$(git -C "$path" rev-parse --abbrev-ref HEAD)" != "$(fabriek_factory_shared_branch)" ]
}

# A clone whose HEAD came back unborn -- an origin whose HEAD names a branch it
# does not have, an interrupted fetch -- used to leave a directory behind. The
# ensure skips a path that exists, so every later run reused it and failed with
# "no commit to read a declaration from", which says nothing about the clone and
# cannot be recovered from without somebody deleting the directory by hand.
@test "a clone that came back without a commit is not left behind to be reused" {
	local origin="$TEST_TEMP_DIR/origin.git"
	git init -q --bare "$origin"
	# Only refs/heads/main exists, and the bare repo's HEAD names another
	# branch, so git clone checks out nothing.
	local seed="$TEST_TEMP_DIR/seed"
	git init -q "$seed"
	git -C "$seed" config user.email t@invalid
	git -C "$seed" config user.name t
	touch "$seed/README.md"
	git -C "$seed" add -A
	git -C "$seed" -c commit.gpgsign=false commit -qm first
	git -C "$seed" push -q "$origin" HEAD:refs/heads/main
	git -C "$origin" symbolic-ref HEAD refs/heads/nowhere

	run fabriek_factory_clone_ensure "$STATE" acme "$origin"
	assert_failure
	assert_output --partial "no commit"

	# And nothing is left for the next run to trip over.
	[ ! -d "$STATE/factories/acme" ]
}

# The operator's checkout is the operator's, and the supervisor that clones
# it and fetches the pin from it is root (ADR-067 point 5). git refuses a
# repository another uid owns unless told it is safe, and it checks on the
# clone and on every fetch. GIT_TEST_ASSUME_DIFFERENT_OWNER makes git treat
# every repository as foreign; the global config here trusts the state
# directory, which is the supervisor's own, and nothing else.
foreign_origin() {
	local origin="$1"
	git init -q -b main "$origin"
	git -C "$origin" config user.name o
	git -C "$origin" config user.email o@x
	git -C "$origin" config commit.gpgsign false
	echo x >"$origin/a.txt"
	git -C "$origin" add a.txt
	git -C "$origin" commit -qm one
	export GIT_CONFIG_GLOBAL="$TEST_TEMP_DIR/gitconfig"
	git config --global safe.directory "$STATE/*"
	export GIT_TEST_ASSUME_DIFFERENT_OWNER=1
}

@test "the operator's checkout is cloned though the supervisor does not own it" {
	origin="$TEST_TEMP_DIR/origin3"
	foreign_origin "$origin"

	run fabriek_factory_clone_ensure "$STATE" acme3 "$origin"
	assert_success
	refute_output --partial "dubious"
	run git -C "$STATE/factories/acme3" rev-parse --verify refs/heads/main
	assert_success
}

# Found on a host (2026-09-25, ADR-070): in a fresh machine every role's
# first session asks for the clone at once, and all but one met
# "destination path already exists" and failed to start.
@test "sessions asking for the clone at once all get it, and one clone is made" {
	origin="$TEST_TEMP_DIR/origin"
	git init -q -b main "$origin"
	git -C "$origin" -c user.name=o -c user.email=o@x -c commit.gpgsign=false commit -q --allow-empty -m one
	local i
	for i in 1 2 3 4 5 6; do
		(fabriek_factory_clone_ensure "$STATE" acme "$origin" >"$TEST_TEMP_DIR/out-$i" 2>&1; echo $? >"$TEST_TEMP_DIR/rc-$i") &
	done
	wait
	for i in 1 2 3 4 5 6; do
		[ "$(cat "$TEST_TEMP_DIR/rc-$i")" = 0 ] || { cat "$TEST_TEMP_DIR/out-$i"; return 1; }
	done
	run git -C "$STATE/factories/acme" rev-parse --verify HEAD
	assert_success
}
