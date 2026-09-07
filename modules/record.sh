# shellcheck shell=bash
## The factory's shared record (ADR-022).
##
## Issues and comments are git objects under refs/bugs, so the record lives in
## the repository the factory works and travels with it. git-bug keeps the
## acting identity in a repository-local git config key with no per-invocation
## flag, so the identity is set immediately before each write.
##
## Nothing here calls git-bug directly. Every call goes through the wrapper
## below, for the reasons ADR-024 records.
##
## Sourced by store path into cageworks-container alongside names.sh.

## git-bug 0.10.1 takes an exclusive lock on the whole repository for every
## operation, reads included, and fails immediately rather than waiting. Four
## of five concurrent reads die. It fails in three ways, of which only the
## first is the lock working: the other two are its own unlock race, where one
## process removes a lock it does not hold and the next reads the file that is
## no longer there or is not yet written. All three are transient, so all three
## are retried. Treating only the honest one as retryable cost the spike an
## agent after a wrapper was already in place.
##
## And it does not always fail. Under contention a write can stop answering
## altogether: four concurrent `label new` calls were found still running
## forty-five minutes later. A retry loop is no use against that, because
## there is nothing to retry from, so every attempt is bounded and a killed
## attempt counts as transient.
cageworks_record_transient() {
	local err="$1" status="$2"
	## The attempt was killed rather than answered. 124 is timeout reporting
	## the deadline; 143 and 137 are the process dying on the TERM and the
	## KILL that follows it, which is what happens when the deadline lands
	## while it is inside a call that does not return. git-bug breaks a lock
	## whose holder is gone, so the next attempt is not blocked by this one.
	case "$status" in
	124 | 137 | 143) return 0 ;;
	esac
	## The last three are the search index rather than the lock. "EOF" is a
	## read of an index another agent is part way through rebuilding, "cannot
	## create new index" is two agents rebuilding it at once, and "directory
	## not empty" is git-bug's own cleanup of an index directory somebody else
	## is writing into. Retrying is right and reading any of them as an answer
	## is not: like the lock races above they are bounded, so a failure that is
	## not transient still reaches the caller once the attempts run out.
	grep -qE 'already locked|invalid syntax|lock: no such file or directory|^Error: EOF$|cannot create new index|directory not empty' "$err"
}

## Every git-bug invocation in cageworks. The command is argv and is replayed
## whole, so nothing it needs may arrive on standard input: an attempt that
## consumed a body would retry with an empty one. Bodies are spooled to a file
## by the callers below and passed as -F <file>, which is also how nothing a
## role writes reaches a command line.
##
## A failed attempt may still have written. The unlock race reports a failure
## after the commit is made, so retrying blind adds a second comment, or gets
## "no label added or removed" for a label the first attempt applied. The
## caller passes the name of a function that answers whether the write landed,
## and that answer is asked of the record rather than inferred from the error.
##
## The check is state, never prose: a label being present, or a count of
## comments having gone up. Nothing here reads what anybody wrote.
cageworks_git_bug_confirmed() {
	local repo="$1" landed="$2"
	shift 2
	local attempts bound err i status
	attempts="${CAGEWORKS_RECORD_ATTEMPTS:-60}"
	## Long enough that no healthy call is cut short, short enough that a
	## wedged one does not hold a role's turn open.
	bound="${CAGEWORKS_RECORD_TIMEOUT:-30}"
	err="$(mktemp)"
	for ((i = 1; i <= attempts; i++)); do
		(cd "$repo" && timeout -k 5 "$bound" git-bug "$@") 2>"$err"
		status=$?
		if [ "$status" -eq 0 ]; then
			rm -f "$err"
			return 0
		fi
		if [ -n "$landed" ] && "$landed"; then
			rm -f "$err"
			return 0
		fi
		if ! cageworks_record_transient "$err" "$status"; then
			cat "$err" >&2
			rm -f "$err"
			return "$status"
		fi
		## Jittered, so two agents that collided once do not collide again on
		## the same schedule.
		sleep "0.$((RANDOM % 3 + 1))"
	done
	## Saying so is the decision (ADR-024 point 4). A reader that gave up
	## quietly would return nothing, and a record with no work in it returns
	## nothing too.
	cat "$err" >&2
	rm -f "$err"
	return 1
}

## git-bug answers a label query from a search index it keeps beside the
## record, and concurrent writes leave that index wrong: four writers landing
## four labels were repeatedly followed by a query returning two or three, with
## every write reporting success and `bug show` listing every label. It does
## not heal, so the work stays invisible for as long as the index survives.
##
## The index is a cache of what the git objects already say, and deleting it
## makes the next reader rebuild it. So a writer drops it. Racing to delete a
## directory that is already gone is harmless, and a reader that catches the
## rebuild mid-flight fails in one of the ways the wrapper already retries.
##
## This is a work-around for somebody else's defect, like the retry above, and
## the reason both are here rather than in a caller is that forgetting either
## one loses work silently.
cageworks_record_drop_index() {
	local repo="$1" idx dead
	idx="$repo/.git/git-bug/indexes"
	[ -d "$idx" ] || return 0
	dead="$idx.dropped.$$"
	## Moved aside and then deleted, because deleting in place is not atomic:
	## rm walks the tree while another agent's rebuild is writing into it,
	## fails with "Directory not empty", and leaves a half-built index for the
	## next reader to fail on. A rename either happens or does not.
	mv "$idx" "$dead" 2>/dev/null || return 0
	rm -rf "$dead"
}

## A call with nothing to confirm: every read, and the one write that cannot
## be checked for having landed.
cageworks_git_bug() {
	local repo="$1"
	shift
	cageworks_git_bug_confirmed "$repo" "" "$@"
}

## The identity git-bug writes as, for one role. Created on first use and found
## again after. The full id matters: git-bug accepts a truncated one and then
## fails silently, which is how a builder's comment was once attributed to the
## architect.
cageworks_record_identity() {
	local repo="$1" role="$2"
	cageworks_name_ok "$role" || return 1

	## git-bug has no -C: it works on the repository it is run in, so the
	## wrapper moves there for every call.
	local listed existing
	listed="$(cageworks_git_bug "$repo" user --format json)" || return 1
	existing="$(printf '%s\n' "$listed" |
		awk -v role="$role" '
			/"id":/   { gsub(/[",]/, "", $2); id = $2 }
			/"name":/ { gsub(/[",]/, "", $2); if ($2 == role) { print id; exit } }
		')"
	if [ -n "$existing" ]; then
		echo "$existing"
		return 0
	fi

	cageworks_git_bug "$repo" user new --non-interactive \
		--name "$role" --email "$role@factory.invalid" | tail -1
}

## Write as this role for the duration of one command. The arguments are
## git-bug's, without the program name, because the wrapper supplies it.
##
## Setting the identity and making the write are two operations against one
## repository-local config key, and a peer writing as itself in between would
## attribute this write to the wrong role. git-bug's own lock does not cover
## the gap, since the config key is not part of what it locks. Roles write
## rarely and at the end of a turn, and closing this properly means a per-call
## identity flag, which is a change in git-bug rather than here.
cageworks_record_as_confirmed() {
	local repo="$1" role="$2" landed="$3"
	shift 3
	local id
	id="$(cageworks_record_identity "$repo" "$role")" || return 1
	[ -n "$id" ] || return 1
	git -C "$repo" config git-bug.identity "$id" || return 1
	cageworks_git_bug_confirmed "$repo" "$landed" "$@"
}

## Filing an item is the one write with nothing to confirm against: there is no
## id to look for until it succeeds, and matching on a title would make two
## agents filing the same title into one item. A retry after a partial write
## therefore files it twice. Items are filed by the supervisor rather than by
## agents racing, which is what keeps that narrow.
cageworks_record_as() {
	local repo="$1" role="$2"
	shift 2
	cageworks_record_as_confirmed "$repo" "$role" "" "$@"
}

## File an item. The body comes from standard input, so nothing about it
## reaches a command line; git-bug takes the first line as the title.
cageworks_record_new() {
	local repo="$1" role="$2"
	local body status
	body="$(mktemp)"
	cat >"$body"
	cageworks_record_as "$repo" "$role" \
		bug new --non-interactive -F "$body" |
		tail -1 | cut -d' ' -f1
	status="${PIPESTATUS[0]}"
	cageworks_record_drop_index "$repo"
	rm -f "$body"
	return "$status"
}

cageworks_record_comment() {
	local repo="$1" item="$2" role="$3"
	local body status before

	## Whether the comment landed is a count going up, not a body being
	## recognised. Retrying without asking is how one outcome becomes two.
	before="$(cageworks_record_count "$repo" "$item")" || return 1
	[ -n "$before" ] || before=0

	body="$(mktemp)"
	cat >"$body"
	# shellcheck disable=SC2329  # called by name through the wrapper's hook
	cageworks_record_commented() {
		[ "$(cageworks_record_count "$repo" "$item")" -gt "$before" ]
	}
	cageworks_record_as_confirmed "$repo" "$role" cageworks_record_commented \
		bug comment new --non-interactive -F "$body" "$item" >/dev/null
	status=$?
	unset -f cageworks_record_commented
	cageworks_record_drop_index "$repo"
	rm -f "$body"
	return "$status"
}

cageworks_record_show() {
	local repo="$1" item="$2"
	cageworks_git_bug "$repo" bug show "$item"
}

cageworks_record_participants() {
	local repo="$1" item="$2" shown
	shown="$(cageworks_record_show "$repo" "$item")" || return 1
	printf '%s\n' "$shown" | sed -n 's/^participants: //p'
}

## A mention is metadata, never prose: the supervisor acts on it without
## reading anything an agent wrote. A colon would break git-bug's own query
## parser, so the label is written with a dash.
cageworks_record_mention_label() {
	local role="$1"
	cageworks_name_ok "$role" || return 1
	echo "needs-$role"
}

cageworks_record_mention() {
	local repo="$1" item="$2" role="$3"
	local label
	label="$(cageworks_record_mention_label "$role")" || return 1

	## Asking for a label that is already there is the state the caller wanted,
	## whether this attempt put it there or the one before it did.
	# shellcheck disable=SC2329  # called by name through the wrapper's hook
	cageworks_record_labelled() {
		cageworks_record_show "$repo" "$item" 2>/dev/null |
			sed -n 's/^labels: //p' | grep -qw -- "$label"
	}
	local status
	cageworks_git_bug_confirmed "$repo" cageworks_record_labelled \
		bug label new "$item" "$label" >/dev/null
	status=$?
	unset -f cageworks_record_labelled
	cageworks_record_drop_index "$repo"
	return "$status"
}

## Everything marked for a role, found by label alone.
cageworks_record_needing() {
	local repo="$1" role="$2"
	local label
	label="$(cageworks_record_mention_label "$role")" || return 1
	## Dropping it on the way in as well as on the way out. A rebuild that
	## started before a write lands after the writer invalidated, so a writer
	## dropping the index does not by itself guarantee the next reader sees a
	## fresh one. This is the read where being wrong means an agent does not
	## see work that exists.
	cageworks_record_drop_index "$repo"
	cageworks_git_bug "$repo" bug "label:$label" --format id
}

## Take what a role wrote during its turn and put it in the record. Comments
## are files it dropped in its run directory; mentions are a list of role
## names. Both arrive as files because a cage cannot reach the record, and the
## supervisor posts them as that role.
##
## A malformed mention is refused rather than failing the turn: the work the
## role did is not less real because it asked for someone who does not exist.
cageworks_record_ingest() {
	local repo="$1" run_dir="$2" role="$3" item="$4"

	local file
	if [ -d "$run_dir/comments" ]; then
		for file in "$run_dir/comments"/*; do
			[ -f "$file" ] || continue
			[ -s "$file" ] || continue
			cageworks_record_comment "$repo" "$item" "$role" <"$file" || return 1
		done
	fi

	if [ -f "$run_dir/mentions" ]; then
		local mentioned
		while IFS= read -r mentioned; do
			[ -n "$mentioned" ] || continue
			cageworks_record_mention "$repo" "$item" "$mentioned" ||
				echo "cageworks: not a role, so not mentioned: $mentioned" >&2
		done <"$run_dir/mentions"
	fi
}

## How much of an item a role has already been shown. Markers are the
## supervisor's bookkeeping rather than part of the record: what a role has
## read is nobody else's business and does not belong in a shared history.
cageworks_record_seen() {
	local root="$1" factory="$2" role="$3" item="$4"
	cageworks_name_ok "$factory" || return 1
	cageworks_name_ok "$role" || return 1
	local file="$root/$factory/$role/$item"
	if [ -f "$file" ]; then
		cat "$file"
	else
		echo 0
	fi
}

cageworks_record_mark_seen() {
	local root="$1" factory="$2" role="$3" item="$4" count="$5"
	cageworks_name_ok "$factory" || return 1
	cageworks_name_ok "$role" || return 1
	local dir="$root/$factory/$role"
	mkdir -p "$dir"
	local tmp="$dir/.$item.$$"
	printf '%s' "$count" >"$tmp" && mv "$tmp" "$dir/$item"
}

## The number of comments on an item, which is what a marker counts.
##
## The read is captured before it is counted. A pipeline reports the status of
## its last stage, so counting a failed read would report zero comments with a
## clean exit, and zero is a number a caller acts on (ADR-024 point 4).
cageworks_record_count() {
	local repo="$1" item="$2" shown
	shown="$(cageworks_record_show "$repo" "$item")" || return 1
	printf '%s\n' "$shown" | grep -cE '^ *[0-9a-f]{7} #[0-9]+ ' || true
}

## Only what arrived after the first n comments. A role opening its turn is
## shown the whole item for context and this for attention, because replaying
## everything as though it were new is how a record stops being read.
cageworks_record_since() {
	local repo="$1" item="$2" skip="$3" shown
	shown="$(cageworks_record_show "$repo" "$item")" || return 1
	printf '%s\n' "$shown" |
		awk -v skip="$skip" '
			/^ *[0-9a-f]{7} #[0-9]+ / { seen++; show = (seen > skip) }
			show { print }
		'
}
