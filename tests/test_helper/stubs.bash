#!/usr/bin/env bash
# The stubs the machine program's scenarios share: a forge (its CLI and
# its API), a nix whose build answers with a profile per role, and a
# recorder for a command whose call is the assertion. Each writes what it
# was asked to a file the scenario reads. Sourced after common.bash, and
# every function wants STUB_DIR on PATH.

## A recording stub: every call appends its arguments to the file named.
## stub_record <command> <calls-file>
stub_record() {
	cat >"$STUB_DIR/$1" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$2"
EOF
	chmod +x "$STUB_DIR/$1"
}

## The forge's own CLI and its API, keeping their state under the
## directory named: users it was asked to make, tokens it minted, the
## repository, labels, issues. The API refuses a token given on the
## command line, because that is the thing to keep off it.
## stub_forge <forge-dir>
stub_forge() {
	local FORGE="$1"
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
"GET /repos/operator/acme/branches/main") [ -e "$FORGE/has-main" ] && echo '{"name":"main"}' || { echo '{}'; exit 22; } ;;
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
	chmod +x "$STUB_DIR/forgejo" "$STUB_DIR/curl"
}

## nix: build answers with a store path named after the role it was asked
## for, and records the line under the calls directory; a marker file
## fail-<role> there makes that role's build fail. Everything else is the
## real nix.
## stub_nix_build <calls-dir> <real-nix> <store-dir>
stub_nix_build() {
	local CALLS="$1" REAL_NIX="$2" STORE="$3"
	# nix: build answers with a store path named after the role it was
	# asked for, and records the line; everything else is the real nix.
	cat >"$STUB_DIR/nix" <<EOF
#!/usr/bin/env bash
if [ "\$1" = build ]; then
	printf '%s\n' "\$*" >>"$CALLS/nix-build"
	role="\$(printf '%s\n' "\$*" | sed -n 's/.*role = "\([^"]*\)".*/\1/p')"
	if [ -e "$CALLS/fail-\$role" ]; then echo "error: role \$role names devShell backend, which the repository does not define" >&2; exit 1; fi
	out="$STORE/fabriek-role-\$role"
	mkdir -p "\$out/share/fabriek/specialist/skills" "\$out/bin"
	echo '{}' >"\$out/share/fabriek/specialist/lsp.json"
	echo '{}' >"\$out/share/fabriek/specialist/tests.json"
	echo "## \$role" >"\$out/share/fabriek/specialist/APPEND_SYSTEM.md"
	echo "\$out"
	exit 0
fi
exec "$REAL_NIX" "\$@"
EOF
	chmod +x "$STUB_DIR/nix"
}
