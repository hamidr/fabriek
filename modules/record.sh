# shellcheck shell=bash
## The factory's shared record (ADR-013).
##
## Issues and comments are git objects under refs/bugs, so the record lives in
## the repository the factory works and travels with it. The supervisor is the
## only writer: git-bug keeps the acting identity in a repository-local git
## config key with no per-invocation flag, so in the one clone roles share
## there is exactly one acting identity at a time, and it is set before each
## write.
##
## Sourced by store path into nixcage-container alongside role-uid.sh.

## The identity git-bug writes as, for one role. Created on first use and found
## again after. The full id matters: git-bug accepts a truncated one and then
## fails silently, which is how a builder's comment was once attributed to the
## architect.
nixcage_record_identity() {
	local repo="$1" role="$2"
	nixcage_role_name_ok "$role" || return 1

	## git-bug has no -C: it works on the repository it is run in, so every
	## call happens in a subshell that has moved there.
	local existing
	existing="$(cd "$repo" && git-bug user --format json 2>/dev/null |
		awk -v role="$role" '
			/"id":/   { gsub(/[",]/, "", $2); id = $2 }
			/"name":/ { gsub(/[",]/, "", $2); if ($2 == role) { print id; exit } }
		')"
	if [ -n "$existing" ]; then
		echo "$existing"
		return 0
	fi

	(cd "$repo" && git-bug user new --non-interactive \
		--name "$role" --email "$role@factory.invalid" 2>/dev/null) | tail -1
}

## Write as this role for the duration of one command. Nothing else may write
## the record concurrently, which holds because the supervisor is the only
## writer and it works one item at a time.
nixcage_record_as() {
	local repo="$1" role="$2"
	shift 2
	local id
	id="$(nixcage_record_identity "$repo" "$role")" || return 1
	[ -n "$id" ] || return 1
	git -C "$repo" config git-bug.identity "$id" || return 1
	(cd "$repo" && "$@")
}

## File an item. The body comes from standard input, so nothing about it
## reaches a command line; git-bug takes the first line as the title.
nixcage_record_new() {
	local repo="$1" role="$2"
	nixcage_record_as "$repo" "$role" \
		git-bug bug new --non-interactive -F - |
		tail -1 | cut -d' ' -f1
}

nixcage_record_comment() {
	local repo="$1" item="$2" role="$3"
	nixcage_record_as "$repo" "$role" \
		git-bug bug comment new --non-interactive -F - "$item" >/dev/null
}

nixcage_record_show() {
	local repo="$1" item="$2"
	(cd "$repo" && git-bug bug show "$item" 2>/dev/null)
}

nixcage_record_participants() {
	local repo="$1" item="$2"
	(cd "$repo" && git-bug bug show "$item" 2>/dev/null) |
		sed -n 's/^participants: //p'
}

## A mention is metadata, never prose: the supervisor acts on it without
## reading anything an agent wrote. A colon would break git-bug's own query
## parser, so the label is written with a dash.
nixcage_record_mention_label() {
	local role="$1"
	nixcage_role_name_ok "$role" || return 1
	echo "needs-$role"
}

nixcage_record_mention() {
	local repo="$1" item="$2" role="$3"
	local label
	label="$(nixcage_record_mention_label "$role")" || return 1
	(cd "$repo" && git-bug bug label new "$item" "$label" >/dev/null 2>&1)
}

## Everything marked for a role, found by label alone.
nixcage_record_needing() {
	local repo="$1" role="$2"
	local label
	label="$(nixcage_record_mention_label "$role")" || return 1
	(cd "$repo" && git-bug bug "label:$label" --format id 2>/dev/null)
}

## Take what a role wrote during its turn and put it in the record. Comments
## are files it dropped in its run directory; mentions are a list of role
## names. Both arrive as files because a cage cannot reach the record, and the
## supervisor posts them as that role.
##
## A malformed mention is refused rather than failing the turn: the work the
## role did is not less real because it asked for someone who does not exist.
nixcage_record_ingest() {
	local repo="$1" run_dir="$2" role="$3" item="$4"

	local file
	if [ -d "$run_dir/comments" ]; then
		for file in "$run_dir/comments"/*; do
			[ -f "$file" ] || continue
			[ -s "$file" ] || continue
			nixcage_record_comment "$repo" "$item" "$role" <"$file" || return 1
		done
	fi

	if [ -f "$run_dir/mentions" ]; then
		local mentioned
		while IFS= read -r mentioned; do
			[ -n "$mentioned" ] || continue
			nixcage_record_mention "$repo" "$item" "$mentioned" ||
				echo "nixcage: not a role, so not mentioned: $mentioned" >&2
		done <"$run_dir/mentions"
	fi
}
