#!/usr/bin/env bats
# What fabriek up makes on a machine after it boots, and makes again
# without changing anything (ADR-036, roadmap 2.3): a password per bus user,
# an operator account and token on the forge, the factory's repository, an
# account and an issue-scoped token per role, a read-only one for the decider,
# a label per stage, and one memory issue per role, opened as that role.
#
# The forge's CLI, its API and systemctl are stubbed. The stubs keep a small
# state of what was made, so a second run against them is a real second run.

load ../test_helper/common
load ../test_helper/stubs

setup() {
	setup_temp_dir
	STATE="$TEST_TEMP_DIR/state"
	STUB_DIR="$TEST_TEMP_DIR/bin"
	ETC="$TEST_TEMP_DIR/etc"
	FORGE="$TEST_TEMP_DIR/forge"
	mkdir -p "$STATE" "$STUB_DIR" "$ETC" "$FORGE"
	PATH="$STUB_DIR:$PATH"
	export PATH STATE
	RUN="$TEST_TEMP_DIR/run"
	mkdir -p "$RUN"
	export FABRIEK_STATE="$STATE" FABRIEK_ETC="$ETC" FABRIEK_RUN="$RUN" FABRIEK_FACTORY=acme
	# The forge's state on a host, and the lock its CLI takes beside it
	# (ADR-068 point 5); here a directory of the suite's own.
	export FABRIEK_FORGE_STATE="$TEST_TEMP_DIR/forge-state"
	# Where a push of main to the forge lands here: a bare repository, so no
	# test waits on an address that is not on this host.
	git init -q --bare -b main "$TEST_TEMP_DIR/forge.git"
	export FABRIEK_FORGE_GIT_URL="$TEST_TEMP_DIR/forge.git"

	cat >"$ETC/declaration.json" <<'JSON'
{ "name": "acme",
  "roles": { "builder": { "command": ["pi"], "provides": ["build"] },
             "reviewer": { "command": ["pi"], "provides": ["review"] } },
  "workflows": { "ship": { "stages": [ { "needs": "build" }, { "needs": "review" } ] } } }
JSON
	cat >"$ETC/bridge.json" <<'JSON'
{ "bridge": "fabriek-acme", "host": "10.77.0.1", "prefix": 24,
  "cages": { "builder": "10.77.0.10", "reviewer": "10.77.0.11", "decider": "10.77.0.2" },
  "proxy": "10.77.0.1:8118", "forgejo": "10.77.0.1:3000", "bus": "10.77.0.1:4222" }
JSON

	stub_forge "$FORGE"
	stub_bus "$TEST_TEMP_DIR/bus-calls"
	cat >"$STUB_DIR/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$FORGE/systemctl-calls"
EOF
	# The uid a role's credentials must belong to, and the chown that gives
	# them to it, which the suite cannot do for real.
	cat >"$STUB_DIR/nixcage-container" <<EOF
#!/usr/bin/env bash
case "\${2#acme-}" in builder) echo 60000 ;; reviewer) echo 60064 ;; tester) echo 60128 ;; decider) echo 60192 ;; *) exit 1 ;; esac
EOF
	cat >"$STUB_DIR/chown" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$FORGE/chown-calls"
EOF
	chmod +x "$STUB_DIR/forgejo" "$STUB_DIR/curl" "$STUB_DIR/systemctl" "$STUB_DIR/nixcage-container" "$STUB_DIR/chown"
}

teardown() {
	teardown_temp_dir
}

@test "given a fresh machine, prepare makes a password for every bus user and writes the account's users" {
	run_fabriek_container factory-prepare acme
	assert_success
	for user in builder reviewer decider executor probes; do
		[ -s "$STATE/bus/$user" ]
		[ "$(stat -c %a "$STATE/bus/$user")" = 400 ]
	done
	run cat "$FORGE/systemctl-calls"
	assert_output --partial "reload nats.service"
	## The file the host's server includes, with this factory's users in it
	## and no password of theirs (ADR-069 point 3).
	run jq -r '[.[].user] | sort | join(",")' <<<"$(sed '1d; s/^users = //' "$ETC/nats-users.conf")"
	assert_output "acme-builder,acme-decider,acme-executor,acme-probes,acme-reviewer"
	run grep -c -F "$(cat "$STATE/bus/builder")" "$ETC/nats-users.conf"
	assert_output 0
}

# The executor starts every session, and a session started before its
# credentials are the role's is one that fails or is deaf. Found on a first
# boot: the decider logged EACCES on its token until prepare had chowned it.
@test "prepare marks the machine prepared after the last credential is handed over, and starts the executor on it" {
	run_fabriek_container factory-prepare acme
	assert_success
	# Under /run, per boot: the lifecycle model found a mark on the pool
	# outliving the credentials it was written for (ADR-057).
	[ -f "$RUN/prepared" ]
	[ ! -e "$STATE/prepared" ]
	run cat "$FORGE/systemctl-calls"
	assert_output --partial "restart fabriek-acme-executor"
	# The probes exit clean before a declaration and are restarted on
	# failure only, so without this a fresh boot has no probes (measured
	# 2026-09-16: "no factory prepared yet", then silence).
	assert_output --partial "restart fabriek-probes"
	# the mark is the last thing written: after the decider's chown
	[ "$(tail -1 "$FORGE/chown-calls")" = "60192 $STATE/bus/decider $STATE/forge/decider-token" ]
}

@test "prepare makes the factory's owner account, which is not an admin, and its token and repository once" {
	run_fabriek_container factory-prepare acme
	assert_success
	[ -s "$STATE/forge/operator-token" ]
	run grep -c "admin user create --username acme-operator" "$FORGE/cli-calls"
	assert_output 1
	run grep -c -- "--admin" "$FORGE/cli-calls"
	assert_output 0
	run grep -c "generate-access-token --username acme-operator .*--scopes all" "$FORGE/cli-calls"
	assert_output 1
	run grep -c "^POST /user/repos\|POST.*/user/repos" "$FORGE/api-calls"
	assert_output 1
}

# ADR-068 moved every factory onto one Forgejo, so a token file kept from
# the instance a factory had before names an account that instance held and
# this one does not. Found on a host: up failed at the repository, because
# prepare kept a token the forge answered 401 to.
@test "a token the forge no longer honours is minted again, and the file is the new one" {
	run_fabriek_container factory-prepare acme
	assert_success
	local before
	before="$(cat "$STATE/forge/operator-token")"
	chmod u+w "$STATE/forge/operator-token"
	printf 'token-of-the-instance-that-is-gone\n' >"$STATE/forge/operator-token"
	run_fabriek_container factory-prepare acme
	assert_success
	[ "$(cat "$STATE/forge/operator-token")" = "$before" ]
	run grep -c "generate-access-token --username acme-operator" "$FORGE/cli-calls"
	assert_output 3
}

# There is no CLI that deletes an access token, so the name the first one
# took is taken for good; a second is minted under a name of its own rather
# than failing the whole prepare.
@test "a token minted again takes a name the account has not used" {
	run_fabriek_container factory-prepare acme
	assert_success
	chmod u+w "$STATE/forge/operator-token"
	printf 'token-of-the-instance-that-is-gone\n' >"$STATE/forge/operator-token"
	run_fabriek_container factory-prepare acme
	assert_success
	run grep -c "^acme-operator fabriek$" "$FORGE/tokens"
	assert_output 1
	run grep -c "^acme-operator fabriek-" "$FORGE/tokens"
	assert_output 1
}

@test "every role gets an account, read on the repository, and a write:issue token kept as a file" {
	run_fabriek_container factory-prepare acme
	assert_success
	for role in builder reviewer; do
		[ "$(cat "$STATE/forge/$role-token")" = "token-for-acme-$role" ]
		run grep -c "generate-access-token --username acme-$role .*--scopes write:issue" "$FORGE/cli-calls"
		assert_output 1
	done
	run sort "$FORGE/collaborators"
	assert_output --partial acme-builder
	assert_output --partial acme-reviewer
	run grep -c '"permission":"read"' "$FORGE/api-calls"
	assert_output 3
}

@test "a role's bus password and forge token belong to the role's uid, so its cage can read them and nothing else can" {
	run_fabriek_container factory-prepare acme
	assert_success
	run cat "$FORGE/chown-calls"
	assert_output --partial "60000 $STATE/bus/builder $STATE/forge/builder-token"
	assert_output --partial "60064 $STATE/bus/reviewer $STATE/forge/reviewer-token"
	[ "$(stat -c %a "$STATE/forge/builder-token")" = 400 ]
}

@test "given the repository's origin, prepare files it on the machine for every session the executor starts" {
	run_fabriek_container factory-prepare acme https://forge.example/acme.git
	assert_success
	[ "$(cat "$STATE/origin")" = "https://forge.example/acme.git" ]
	run_fabriek_container factory-prepare acme
	assert_success
	[ "$(cat "$STATE/origin")" = "https://forge.example/acme.git" ]
}

# Found on a machine: the CLI's user list came back empty once, prepare tried
# to create an account that existed, and the whole boot failed on it.
@test "an account the list could not show is confirmed by the create that finds it there" {
	run_fabriek_container factory-prepare acme
	assert_success
	touch "$FORGE/list-fails-once"
	run_fabriek_container factory-prepare acme
	assert_success
	[ "$(grep -c '^acme-builder$' "$FORGE/users")" = 1 ]
}

@test "the decider gets an account and a token that can only read" {
	run_fabriek_container factory-prepare acme
	assert_success
	run grep -c "generate-access-token --username acme-decider .*--scopes read:issue" "$FORGE/cli-calls"
	assert_output 1
	[ "$(cat "$STATE/forge/decider-token")" = "token-for-acme-decider" ]
}

# The decider is a cage like a role's, and its files are bound the same way;
# found on a machine whose decider logged EACCES on its token every turn.
@test "the decider's bus password and forge token belong to the decider's uid" {
	run_fabriek_container factory-prepare acme
	assert_success
	run cat "$FORGE/chown-calls"
	assert_output --partial "60192 $STATE/bus/decider $STATE/forge/decider-token"
}

# The executor moves assigning and assigned as labels too (ADR-033 point 4),
# and a label the forge lacks is a refused assign. Found on a host: the first
# assign of the system journey was refused for the label prepare never made.
@test "a label exists for every stage's capability, plus the executor's assigning, assigned and blocked, and memory" {
	run_fabriek_container factory-prepare acme
	assert_success
	run sort "$FORGE/labels"
	assert_output "assigned
assigning
blocked
build
memory
review"
}

@test "each role's memory issue is opened as that role, labelled memory and pinned" {
	run_fabriek_container factory-prepare acme
	assert_success
	run jq -r '.title + " by " + .user.login' "$FORGE/issues"
	assert_line --index 0 "memory: builder by acme-builder"
	assert_line --index 1 "memory: reviewer by acme-reviewer"
	run wc -l <"$FORGE/labelled"
	assert_output --regexp '^ *2$'
	run wc -l <"$FORGE/pinned"
	assert_output --regexp '^ *2$'
}

@test "a second prepare changes nothing" {
	run_fabriek_container factory-prepare acme
	assert_success
	local users tokens
	users="$(cat "$FORGE/users")"
	tokens="$(cat "$STATE/bus/builder" "$STATE/forge/builder-token" "$STATE/forge/operator-token")"
	: >"$FORGE/cli-calls"
	: >"$FORGE/api-calls"
	run_fabriek_container factory-prepare acme
	assert_success
	[ "$(cat "$FORGE/users")" = "$users" ]
	[ "$(cat "$STATE/bus/builder" "$STATE/forge/builder-token" "$STATE/forge/operator-token")" = "$tokens" ]
	run grep -c "user create\|generate-access-token" "$FORGE/cli-calls"
	assert_output 0
	run grep -c "POST" "$FORGE/api-calls"
	assert_output 0
	run wc -l <"$FORGE/issues"
	assert_output --regexp '^ *2$'
}

@test "a token never travels on a command line" {
	run_fabriek_container factory-prepare acme
	assert_success
	[ ! -f "$FORGE/leaks" ]
	run grep -c "token-for" "$FORGE/api-calls"
	assert_output 0
}

@test "a role added to the declaration is made on the next prepare, and nothing else is remade" {
	run_fabriek_container factory-prepare acme
	assert_success
	jq '.roles.tester = {command: ["pi"], provides: ["test"]} | .workflows.ship.stages += [{needs: "test"}]' \
		"$ETC/declaration.json" >"$ETC/d.new" && mv "$ETC/d.new" "$ETC/declaration.json"
	: >"$FORGE/cli-calls"
	run_fabriek_container factory-prepare acme
	assert_success
	run grep -c "user create" "$FORGE/cli-calls"
	assert_output 1
	[ -s "$STATE/bus/tester" ]
	[ -s "$STATE/forge/tester-token" ]
	run sort "$FORGE/labels"
	assert_output --partial test
	run wc -l <"$FORGE/issues"
	assert_output --regexp '^ *3$'
}

# The record on origin (ADR-036 point 7): what mirror exported, read back on
# a machine whose board is empty. Memory issues are not restored, because
# each is opened as its role and prepare does that itself.
origin_with_record() {
	local record="$1" origin="$TEST_TEMP_DIR/origin" work="$TEST_TEMP_DIR/record-work"
	git init -q --bare "$origin"
	git init -q "$work"
	printf '%s\n' "$record" >"$work/issues.json"
	git -C "$work" add issues.json
	git -C "$work" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m record
	git -C "$work" push -q "$origin" HEAD:refs/fabriek/record
	echo "$origin"
}

@test "given an empty board and a record on origin, prepare restores the record's issues with their labels and state, memory issues excepted" {
	local origin
	origin="$(origin_with_record '[
	  {"number": 1, "title": "memory: builder", "body": "", "state": "open", "labels": [{"name": "memory"}], "user": {"login": "builder"}},
	  {"number": 2, "title": "ship the login page", "body": "as filed", "state": "open", "labels": [{"name": "build"}], "user": {"login": "operator"}},
	  {"number": 3, "title": "fix the footer", "body": "done long ago", "state": "closed", "labels": [], "user": {"login": "operator"}}
	]')"
	run_fabriek_container factory-prepare acme "$origin"
	assert_success
	run jq -r '.title' "$FORGE/issues"
	assert_output "ship the login page
fix the footer
memory: builder
memory: reviewer"
	run grep -c "issues/1/labels \[4\]" "$FORGE/labelled"
	assert_output 1
	run cat "$FORGE/patched"
	assert_output '/repos/acme-operator/acme/issues/2 {"state":"closed"}'
}

@test "given a board that already has issues, prepare leaves the record on origin alone" {
	local origin
	origin="$(origin_with_record '[{"number": 1, "title": "ship the login page", "body": "", "state": "open", "labels": [], "user": {"login": "operator"}}]')"
	run_fabriek_container factory-prepare acme "$origin"
	assert_success
	run_fabriek_container factory-prepare acme "$origin"
	assert_success
	run wc -l <"$FORGE/issues"
	assert_output --regexp '^ *3$'
}

@test "given a record carrying a label the declaration no longer has, prepare says which and restores the rest" {
	local origin
	origin="$(origin_with_record '[{"number": 1, "title": "deploy it", "body": "", "state": "open", "labels": [{"name": "deploy"}, {"name": "build"}], "user": {"login": "operator"}}]')"
	run_fabriek_container factory-prepare acme "$origin"
	assert_success
	assert_output --partial "deploy"
	run jq -r '.title' "$FORGE/issues"
	assert_line --index 0 "deploy it"
	run grep -c "issues/1/labels \[4\]" "$FORGE/labelled"
	assert_output 1
}

@test "given an origin that carries no record, prepare makes a board of nothing but the memory issues" {
	local origin="$TEST_TEMP_DIR/origin"
	git init -q --bare "$origin"
	run_fabriek_container factory-prepare acme "$origin"
	assert_success
	run wc -l <"$FORGE/issues"
	assert_output --regexp '^ *2$'
	[ ! -f "$FORGE/patched" ]
}

# Merging is a click in Forgejo's UI and nothing else has a verb for it
# (ADR-036), and the UI is on the bridge, where only the machine's own
# transport reaches. The operator's account was made with a password nothing
# kept, so each opening sets a fresh one and says it once.
@test "factory-board answers the board's address on the bridge and a fresh password for the operator, never the same twice" {
	run_fabriek_container factory-prepare acme
	assert_success
	run_fabriek_container factory-board acme
	assert_success
	assert_line --index 0 "10.77.0.1:3000"
	local first="${lines[1]}"
	[ "${#first}" -ge 20 ]
	run grep -c "user change-password --username acme-operator" "$FORGE/cli-calls"
	assert_output 1
	run_fabriek_container factory-board acme
	assert_success
	[ "${lines[1]}" != "$first" ]
}

# The forge's copy of the repository starts empty, and a role's pull request
# and the operator's mirror both need main there (ADR-036 points 5 and 7).
# Found on a host: mirror failed on a forge with no main. The push goes to
# the forge's git URL, which a test points at a bare repository of its own.
@test "given a forge with no main, prepare pushes origin's main to it once, with the token in no argument" {
	local origin="$TEST_TEMP_DIR/origin" forge_git="$TEST_TEMP_DIR/forge.git" work="$TEST_TEMP_DIR/w"
	git init -q --bare -b main "$origin"
	git init -q --bare -b main "$forge_git"
	git init -q -b main "$work"
	echo hi >"$work/README"
	git -C "$work" add README
	git -C "$work" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m first
	git -C "$work" push -q "$origin" main
	FABRIEK_FORGE_GIT_URL="$forge_git" run_fabriek_container factory-prepare acme "$origin"
	assert_success
	run git -C "$forge_git" rev-parse --verify --quiet refs/heads/main
	assert_success
	[ ! -f "$FORGE/leaks" ]
	run grep -c "token-for" "$FORGE/api-calls"
	assert_output 0
	touch "$FORGE/has-main"
	FABRIEK_FORGE_GIT_URL="$TEST_TEMP_DIR/nowhere" run_fabriek_container factory-prepare acme "$origin"
	assert_success
}

# The origin is the operator's checkout and prepare runs as root (ADR-067
# point 5); git refuses a local clone of a repository another uid owns.
# GIT_TEST_ASSUME_DIFFERENT_OWNER makes every repository foreign, and the
# global config here trusts what the machine makes itself and not origin.
@test "main is put on the forge from an origin the machine does not own" {
	local origin="$TEST_TEMP_DIR/origin" forge_git="$TEST_TEMP_DIR/forge.git" work="$TEST_TEMP_DIR/w"
	git init -q --bare -b main "$origin"
	git init -q --bare -b main "$forge_git"
	git init -q -b main "$work"
	echo hi >"$work/README"
	git -C "$work" add README
	git -C "$work" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m first
	git -C "$work" push -q "$origin" main
	export TMPDIR="$TEST_TEMP_DIR/mktemp"
	mkdir -p "$TMPDIR"
	export GIT_CONFIG_GLOBAL="$TEST_TEMP_DIR/gitconfig"
	git config --global --add safe.directory "$TMPDIR/*"
	git config --global --add safe.directory "$STATE/*"
	git config --global --add safe.directory "$forge_git"
	export GIT_TEST_ASSUME_DIFFERENT_OWNER=1
	FABRIEK_FORGE_GIT_URL="$forge_git" run_fabriek_container factory-prepare acme "$origin"
	assert_success
	refute_output --partial "dubious"
	run git -C "$forge_git" rev-parse --verify --quiet refs/heads/main
	assert_success
}
