#!/usr/bin/env bats
# What cageworks up makes on a machine after it boots, and makes again
# without changing anything (ADR-036, roadmap 2.3): a password per bus user,
# an operator account and token on the forge, the factory's repository, an
# account and an issue-scoped token per role, a read-only one for the decider,
# a label per stage, and one memory issue per role, opened as that role.
#
# The forge's CLI, its API and systemctl are stubbed. The stubs keep a small
# state of what was made, so a second run against them is a real second run.

load ../test_helper/common

setup() {
	setup_temp_dir
	STATE="$TEST_TEMP_DIR/state"
	STUB_DIR="$TEST_TEMP_DIR/bin"
	ETC="$TEST_TEMP_DIR/etc"
	FORGE="$TEST_TEMP_DIR/forge"
	mkdir -p "$STATE" "$STUB_DIR" "$ETC" "$FORGE"
	PATH="$STUB_DIR:$PATH"
	export PATH STATE
	export CAGEWORKS_STATE="$STATE" CAGEWORKS_ETC="$ETC"

	cat >"$ETC/declaration.json" <<'JSON'
{ "name": "acme",
  "roles": { "builder": { "command": ["pi"], "provides": ["build"] },
             "reviewer": { "command": ["pi"], "provides": ["review"] } },
  "workflows": { "ship": { "stages": [ { "needs": "build" }, { "needs": "review" } ] } } }
JSON
	cat >"$ETC/bridge.json" <<'JSON'
{ "bridge": "cageworks-acme", "host": "10.77.0.1", "prefix": 24,
  "cages": { "builder": "10.77.0.10", "reviewer": "10.77.0.11", "decider": "10.77.0.2" },
  "proxy": "10.77.0.1:8118", "forgejo": "10.77.0.1:3000", "valkey": "10.77.0.1:6379" }
JSON

	# The forge's own CLI: users it was asked to make, and tokens it minted.
	cat >"$STUB_DIR/forgejo" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$FORGE/cli-calls"
case "\$1 \$2 \$3" in
"admin user list")
	# A list that fails once, when asked to: the forge's CLI opens the
	# database beside the running server and can lose that race.
	if [ -e "$FORGE/list-fails-once" ]; then rm "$FORGE/list-fails-once"; echo "database is locked" >&2; exit 1; fi
	cat "$FORGE/users" 2>/dev/null
	;;
"admin user create")
	while [ \$# -gt 0 ]; do case "\$1" in --username) u="\$2";; esac; shift; done
	if grep -qx "\$u" "$FORGE/users" 2>/dev/null; then echo "Command error: CreateUser: user already exists [name: \$u]" >&2; exit 1; fi
	echo "\$u" >>"$FORGE/users"
	;;
"admin user change-password") ;;
"admin user generate-access-token")
	while [ \$# -gt 0 ]; do case "\$1" in --username) u="\$2";; esac; shift; done
	echo "token-for-\$u"
	;;
esac
EOF
	# The API. Answers what exists, records what was asked for, and refuses a
	# token given on the command line, because that is the thing to keep off it.
	cat >"$STUB_DIR/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$FORGE/api-calls"
method=GET; url=""; body=""
while [ \$# -gt 0 ]; do
	case "\$1" in
	-X) method="\$2"; shift ;;
	-d) body="\$2"; shift ;;
	-H) case "\$2" in Authorization*) echo "token on argv" >>"$FORGE/leaks" ;; esac; shift ;;
	http*) url="\$1" ;;
	esac
	shift
done
path="\${url#*/api/v1}"
case "\$method \$path" in
"GET /repos/operator/acme") [ -f "$FORGE/repo" ] && echo '{"name":"acme"}' || { echo '{}'; exit 22; } ;;
"POST /user/repos") touch "$FORGE/repo"; echo '{"name":"acme"}' ;;
"PUT /repos/operator/acme/collaborators/"*) echo "\${path##*/}" >>"$FORGE/collaborators" ;;
"GET /repos/operator/acme/labels") [ -f "$FORGE/labels" ] && jq -Rn '[inputs] | to_entries | map({id: (.key + 1), name: .value})' <"$FORGE/labels" || echo '[]' ;;
"POST /repos/operator/acme/labels") jq -r .name <<<"\$body" >>"$FORGE/labels"; echo '{"id":1}' ;;
"GET /repos/operator/acme/issues"*) [ -f "$FORGE/issues" ] && jq -Rn '[inputs | fromjson]' <"$FORGE/issues" || echo '[]' ;;
"POST /repos/operator/acme/issues") n=\$(( \$( [ -f "$FORGE/issues" ] && wc -l <"$FORGE/issues" || echo 0 ) + 1 )); jq -c --argjson n "\$n" '. + {number: \$n, labels: [], user: {login: (.title | sub("memory: "; ""))}}' <<<"\$body" >>"$FORGE/issues"; echo "{\"number\": \$n}" ;;
"POST /repos/operator/acme/issues/"*"/labels") echo "\$path \$(jq -c .labels <<<"\$body")" >>"$FORGE/labelled" ;;
"PATCH /repos/operator/acme/issues/"*) echo "\$path \$body" >>"$FORGE/patched" ;;
"POST /repos/operator/acme/issues/"*"/pin") echo "\$path" >>"$FORGE/pinned" ;;
*) echo "unstubbed: \$method \$path" >&2; exit 1 ;;
esac
EOF
	cat >"$STUB_DIR/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$FORGE/systemctl-calls"
EOF
	# The uid a role's credentials must belong to, and the chown that gives
	# them to it, which the suite cannot do for real.
	cat >"$STUB_DIR/nixcage-container" <<EOF
#!/usr/bin/env bash
case "\$2" in builder) echo 60000 ;; reviewer) echo 60064 ;; tester) echo 60128 ;; decider) echo 60192 ;; *) exit 1 ;; esac
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

@test "given a fresh machine, prepare makes a password for every bus user and applies the ACL" {
	run_cageworks_container factory-prepare acme
	assert_success
	for user in builder reviewer decider executor probes; do
		[ -s "$STATE/bus/$user" ]
		[ "$(stat -c %a "$STATE/bus/$user")" = 400 ]
	done
	run cat "$FORGE/systemctl-calls"
	assert_output --partial "restart cageworks-bus-acl"
}

# The executor starts every session, and a session started before its
# credentials are the role's is one that fails or is deaf. Found on a first
# boot: the decider logged EACCES on its token until prepare had chowned it.
@test "prepare marks the machine prepared after the last credential is handed over, and starts the executor on it" {
	run_cageworks_container factory-prepare acme
	assert_success
	[ -f "$STATE/prepared" ]
	run cat "$FORGE/systemctl-calls"
	assert_output --partial "restart cageworks-executor"
	# the mark is the last thing written: after the decider's chown
	[ "$(tail -1 "$FORGE/chown-calls")" = "60192 $STATE/bus/decider $STATE/forge/decider-token" ]
}

@test "prepare makes the operator's account and token once, and the repository once" {
	run_cageworks_container factory-prepare acme
	assert_success
	[ -s "$STATE/forge/operator-token" ]
	run grep -c "admin user create --admin --username operator" "$FORGE/cli-calls"
	assert_output 1
	run grep -c "^POST /user/repos\|POST.*/user/repos" "$FORGE/api-calls"
	assert_output 1
}

@test "every role gets an account, read on the repository, and a write:issue token kept as a file" {
	run_cageworks_container factory-prepare acme
	assert_success
	for role in builder reviewer; do
		[ "$(cat "$STATE/forge/$role-token")" = "token-for-$role" ]
		run grep -c "generate-access-token --username $role .*--scopes write:issue" "$FORGE/cli-calls"
		assert_output 1
	done
	run sort "$FORGE/collaborators"
	assert_output --partial builder
	assert_output --partial reviewer
	run grep -c '"permission":"read"' "$FORGE/api-calls"
	assert_output 3
}

@test "a role's bus password and forge token belong to the role's uid, so its cage can read them and nothing else can" {
	run_cageworks_container factory-prepare acme
	assert_success
	run cat "$FORGE/chown-calls"
	assert_output --partial "60000 $STATE/bus/builder $STATE/forge/builder-token"
	assert_output --partial "60064 $STATE/bus/reviewer $STATE/forge/reviewer-token"
	[ "$(stat -c %a "$STATE/forge/builder-token")" = 400 ]
}

@test "given the repository's origin, prepare files it on the machine for every session the executor starts" {
	run_cageworks_container factory-prepare acme https://forge.example/acme.git
	assert_success
	[ "$(cat "$STATE/origin")" = "https://forge.example/acme.git" ]
	run_cageworks_container factory-prepare acme
	assert_success
	[ "$(cat "$STATE/origin")" = "https://forge.example/acme.git" ]
}

# Found on a machine: the CLI's user list came back empty once, prepare tried
# to create an account that existed, and the whole boot failed on it.
@test "an account the list could not show is confirmed by the create that finds it there" {
	run_cageworks_container factory-prepare acme
	assert_success
	touch "$FORGE/list-fails-once"
	run_cageworks_container factory-prepare acme
	assert_success
	[ "$(grep -c '^builder$' "$FORGE/users")" = 1 ]
}

@test "the decider gets an account and a token that can only read" {
	run_cageworks_container factory-prepare acme
	assert_success
	run grep -c "generate-access-token --username decider .*--scopes read:issue" "$FORGE/cli-calls"
	assert_output 1
	[ "$(cat "$STATE/forge/decider-token")" = "token-for-decider" ]
}

# The decider is a cage like a role's, and its files are bound the same way;
# found on a machine whose decider logged EACCES on its token every turn.
@test "the decider's bus password and forge token belong to the decider's uid" {
	run_cageworks_container factory-prepare acme
	assert_success
	run cat "$FORGE/chown-calls"
	assert_output --partial "60192 $STATE/bus/decider $STATE/forge/decider-token"
}

@test "a label exists for every stage's capability, plus blocked and memory" {
	run_cageworks_container factory-prepare acme
	assert_success
	run sort "$FORGE/labels"
	assert_output "blocked
build
memory
review"
}

@test "each role's memory issue is opened as that role, labelled memory and pinned" {
	run_cageworks_container factory-prepare acme
	assert_success
	run jq -r '.title + " by " + .user.login' "$FORGE/issues"
	assert_line --index 0 "memory: builder by builder"
	assert_line --index 1 "memory: reviewer by reviewer"
	run wc -l <"$FORGE/labelled"
	assert_output --regexp '^ *2$'
	run wc -l <"$FORGE/pinned"
	assert_output --regexp '^ *2$'
}

@test "a second prepare changes nothing" {
	run_cageworks_container factory-prepare acme
	assert_success
	local users tokens
	users="$(cat "$FORGE/users")"
	tokens="$(cat "$STATE/bus/builder" "$STATE/forge/builder-token" "$STATE/forge/operator-token")"
	: >"$FORGE/cli-calls"
	: >"$FORGE/api-calls"
	run_cageworks_container factory-prepare acme
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
	run_cageworks_container factory-prepare acme
	assert_success
	[ ! -f "$FORGE/leaks" ]
	run grep -c "token-for" "$FORGE/api-calls"
	assert_output 0
}

@test "a role added to the declaration is made on the next prepare, and nothing else is remade" {
	run_cageworks_container factory-prepare acme
	assert_success
	jq '.roles.tester = {command: ["pi"], provides: ["test"]} | .workflows.ship.stages += [{needs: "test"}]' \
		"$ETC/declaration.json" >"$ETC/d.new" && mv "$ETC/d.new" "$ETC/declaration.json"
	: >"$FORGE/cli-calls"
	run_cageworks_container factory-prepare acme
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
	git -C "$work" push -q "$origin" HEAD:refs/cageworks/record
	echo "$origin"
}

@test "given an empty board and a record on origin, prepare restores the record's issues with their labels and state, memory issues excepted" {
	local origin
	origin="$(origin_with_record '[
	  {"number": 1, "title": "memory: builder", "body": "", "state": "open", "labels": [{"name": "memory"}], "user": {"login": "builder"}},
	  {"number": 2, "title": "ship the login page", "body": "as filed", "state": "open", "labels": [{"name": "build"}], "user": {"login": "operator"}},
	  {"number": 3, "title": "fix the footer", "body": "done long ago", "state": "closed", "labels": [], "user": {"login": "operator"}}
	]')"
	run_cageworks_container factory-prepare acme "$origin"
	assert_success
	run jq -r '.title' "$FORGE/issues"
	assert_output "ship the login page
fix the footer
memory: builder
memory: reviewer"
	run grep -c "issues/1/labels \[2\]" "$FORGE/labelled"
	assert_output 1
	run cat "$FORGE/patched"
	assert_output '/repos/operator/acme/issues/2 {"state":"closed"}'
}

@test "given a board that already has issues, prepare leaves the record on origin alone" {
	local origin
	origin="$(origin_with_record '[{"number": 1, "title": "ship the login page", "body": "", "state": "open", "labels": [], "user": {"login": "operator"}}]')"
	run_cageworks_container factory-prepare acme "$origin"
	assert_success
	run_cageworks_container factory-prepare acme "$origin"
	assert_success
	run wc -l <"$FORGE/issues"
	assert_output --regexp '^ *3$'
}

@test "given a record carrying a label the declaration no longer has, prepare says which and restores the rest" {
	local origin
	origin="$(origin_with_record '[{"number": 1, "title": "deploy it", "body": "", "state": "open", "labels": [{"name": "deploy"}, {"name": "build"}], "user": {"login": "operator"}}]')"
	run_cageworks_container factory-prepare acme "$origin"
	assert_success
	assert_output --partial "deploy"
	run jq -r '.title' "$FORGE/issues"
	assert_line --index 0 "deploy it"
	run grep -c "issues/1/labels \[2\]" "$FORGE/labelled"
	assert_output 1
}

@test "given an origin that carries no record, prepare makes a board of nothing but the memory issues" {
	local origin="$TEST_TEMP_DIR/origin"
	git init -q --bare "$origin"
	run_cageworks_container factory-prepare acme "$origin"
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
	run_cageworks_container factory-prepare acme
	assert_success
	run_cageworks_container factory-board acme
	assert_success
	assert_line --index 0 "10.77.0.1:3000"
	local first="${lines[1]}"
	[ "${#first}" -ge 20 ]
	run grep -c "user change-password --username operator" "$FORGE/cli-calls"
	assert_output 1
	run_cageworks_container factory-board acme
	assert_success
	[ "${lines[1]}" != "$first" ]
}
