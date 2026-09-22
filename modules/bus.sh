# shellcheck shell=bash
## The bus's users, prepared and prepared again (ADR-033 point 3, ADR-069).
##
## One nats-server serves the host and a factory is an account in it, so
## what a factory writes is the users of its own account: a file the
## server's configuration includes, rendered here from the declaration and
## the passwords under the state directory, and read when the server is
## asked to reload. Nothing here speaks to a running server to set a
## permission.
##
## A password per user, made once and readable by root alone; the file
## carries its bcrypt hash and never the password itself, so the file the
## server reads gives nothing away. The users are the declaration's roles
## plus the three the host provides.
##
## Sourced by store path into fabriek-container beside names.sh.

fabriek_bus_dir() { printf '%s/bus\n' "$1"; }

## Every user the bus has, given the declaration file.
fabriek_bus_users() {
	local declaration="$1"
	jq -r '.roles | keys[]' "$declaration"
	printf '%s\n' decider executor probes
}

## A password, once.
fabriek_bus_ensure_password() {
	local state="$1" user="$2" file
	fabriek_name_ok "$user" || return 1
	file="$(fabriek_bus_dir "$state")/$user"
	[ -s "$file" ] && return 0
	mkdir -p "$(dirname "$file")"
	chmod 0700 "$(dirname "$file")"
	(umask 077 && fabriek_secret >"$file.new") && mv "$file.new" "$file"
	chmod 0400 "$file"
}

## Where the account's users are written, which is where the host's
## configuration includes them from (ADR-069 point 3).
fabriek_bus_users_file() { printf '%s/nats-users.conf\n' "$1"; }

## The one server's configuration, whose directory every include is
## relative to: nats-server resolves an include against the configuration
## file's own directory and against nothing else.
fabriek_bus_config() { printf '%s/nats.conf\n' "${FABRIEK_BUS_CONFIG_DIR:-/var/lib/fabriek}"; }

## What one user may say, as NATS permissions (ADR-033 point 3 in ADR-069
## point 4's words). An account is a subject namespace of its own, so
## nothing here names the factory: what bounds a user is its own account.
##
## Every JetStream call is a request, so the subjects it is made on are
## publish permissions and the reply comes back on the user's own inbox,
## which is the only inbox it may subscribe. A read is a pull on a consumer
## of the stream named in the permission, so a role's right to read is
## bounded by the stream's name and never by a consumer's. A publisher also
## asks a stream when it was made, because an entry's id carries that
## (point 7).
##
## A user's name carries the factory, because nats-server holds one table
## of users for the host and refuses two accounts the same name; the
## subjects stay bare, because they are the account's (ADR-069 point 2).
##
## fabriek_bus_permissions <factory> <user>
fabriek_bus_permissions() {
	local factory="$1" user="$2" inbox="_INBOX.$1-$2.>"
	case "$user" in
	executor)
		## The account's one manager: it makes the streams and reads them all.
		jq -cn '{publish: {allow: [">"]}, subscribe: {allow: [">"]}}'
		;;
	decider)
		jq -cn --arg inbox "$inbox" '
			{publish: {allow: ["commands",
			                   "$JS.API.STREAM.INFO.>",
			                   "$JS.API.CONSUMER.CREATE.>",
			                   "$JS.API.CONSUMER.MSG.NEXT.>"]},
			 subscribe: {allow: [$inbox]}}'
		;;
	probes)
		jq -cn --arg inbox "$inbox" '
			{publish: {allow: ["probes"]}, subscribe: {allow: [$inbox]}}'
		;;
	*)
		jq -cn --arg r "$user" --arg inbox "$inbox" '
			{publish: {allow: ["control.\($r)", "findings.\($r)", "events.\($r)",
			                   "$JS.API.STREAM.INFO.mailbox-\($r)",
			                   "$JS.API.STREAM.INFO.control-\($r)",
			                   "$JS.API.STREAM.INFO.events-\($r)",
			                   "$JS.API.STREAM.INFO.findings",
			                   "$JS.API.CONSUMER.CREATE.mailbox-\($r).>",
			                   "$JS.API.CONSUMER.MSG.NEXT.mailbox-\($r).*",
			                   "$JS.API.CONSUMER.CREATE.findings.>",
			                   "$JS.API.CONSUMER.MSG.NEXT.findings.*"]},
			 subscribe: {allow: [$inbox]}}'
		;;
	esac
}

## A user's password as the server keeps it: bcrypt, made by natscli, with
## the password in its environment rather than its arguments, which /proc
## shows to every uid on the host.
fabriek_bus_hash() {
	local password="$1"
	PASSWORD="$password" nats server passwd
}

## The account's users, written where the server includes them from and
## read at its next reload (ADR-069 point 3).
##
## Under a lock on the file, checked before the server is asked for
## anything: one factory's malformed file is that factory's failure and
## never a failed reload for every other. A user whose password is not
## written yet is left out, which is what a factory never brought up looks
## like.
##
## fabriek_bus_render_users <factory> <state> <etc> <declaration>
fabriek_bus_render_users() {
	local factory="$1" state="$2" etc="$3" declaration="$4"
	local file dir user password entries
	file="$(fabriek_bus_users_file "$etc")"
	dir="$(fabriek_bus_dir "$state")"
	mkdir -p "$etc"
	entries="$(mktemp)"
	echo '[]' >"$entries"
	while IFS= read -r user; do
		[ -s "$dir/$user" ] || continue
		password="$(fabriek_bus_hash "$(cat "$dir/$user")")" || {
			rm -f "$entries"
			return 1
		}
		jq -c --arg u "$factory-$user" --arg p "$password" \
			--argjson perms "$(fabriek_bus_permissions "$factory" "$user")" \
			'. + [{user: $u, password: $p, permissions: $perms}]' "$entries" >"$entries.new" &&
			mv "$entries.new" "$entries"
	done < <(fabriek_bus_users "$declaration")
	{
		printf '## Written by fabriek-container factory-prepare; the host includes it.\n'
		printf 'users = '
		jq . "$entries"
	} >"$file.new"
	rm -f "$entries"
	chmod 0644 "$file.new"
	mv "$file.new" "$file"
}

## Check the whole configuration and ask the server to read it again.
## Checked first, so a file this factory wrote badly is refused here rather
## than at a reload every other factory shares.
##
## fabriek_bus_reload
fabriek_bus_reload() {
	local config
	config="$(fabriek_bus_config)"
	nats-server -t -c "$config" >/dev/null 2>&1 || {
		echo "fabriek: the bus's configuration is not valid with this factory's users; nothing was reloaded" >&2
		return 1
	}
	systemctl reload nats.service
}
