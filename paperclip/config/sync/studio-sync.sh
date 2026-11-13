#!/bin/sh
# =============================================================================
# studio-sync - keeps Paperclip in step with what the owner does in Forgejo, so
# the owner can run the studio from the two web UIs alone.
#
# The studio's flow (paperclip-ops, tools/ai-studio): a developer agent hands
# its issue to review, the Code Reviewer approves, and the issue then waits at
# the "approval" stage for the owner, who merges the pull request in Forgejo.
# Paperclip does not see Forgejo, so every SYNC_INTERVAL seconds this loop
# looks at each issue waiting for the owner and its pull request, and:
#
#   pull request merged            -> closes the issue (the owner's approval)
#   owner requested changes on it  -> returns the issue to its developer
#   it conflicts with main         -> returns the issue to its developer
#   its branch is behind main      -> updates the branch (CI runs again)
#
# It acts in Paperclip with the owner's board key and in Forgejo as its own
# account. It never merges, never approves a pull request and never starts
# work: each action follows something the owner or the reviewer already did.
#
# Environment (sync.env.secrets + docker-compose.yml):
#   PAPERCLIP_URL          http://paperclip:3100
#   PAPERCLIP_HOST         Host header to send (Paperclip only answers to its allowed hostnames)
#   PAPERCLIP_AUTH_HEADER  full header line, e.g. "Authorization: Bearer ..."
#   PAPERCLIP_COMPANY_ID   the studio's company id
#   FORGEJO_URL            http://forgejo.home:3129 (the forgejo-gw relay)
#   FORGEJO_SYNC_TOKEN     token of the studio-sync Forgejo account
#   FORGEJO_ORG            organisation that holds the project repositories
#   FORGEJO_OWNER_USER     the owner's Forgejo login (whose reviews count)
#   SYNC_INTERVAL          seconds between passes (default 90)
# =============================================================================
set -u
: "${PAPERCLIP_URL:?}" "${PAPERCLIP_AUTH_HEADER:?}" "${PAPERCLIP_COMPANY_ID:?}"
: "${FORGEJO_URL:?}" "${FORGEJO_SYNC_TOKEN:?}" "${FORGEJO_ORG:?}" "${FORGEJO_OWNER_USER:?}"
INTERVAL=${SYNC_INTERVAL:-90}
STATE=/tmp/studio-sync; mkdir -p "$STATE"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
# Secrets reach curl through a config on stdin, never through the command line.
pc() { # METHOD PATH [JSON]
  printf 'header = "%s"\n' "$PAPERCLIP_AUTH_HEADER" | curl -sS --fail-with-body --max-time 30 -K - -X "$1" \
    -H 'Content-Type: application/json' ${PAPERCLIP_HOST:+-H "Host: $PAPERCLIP_HOST"} ${3:+--data "$3"} "$PAPERCLIP_URL/api$2"
}
fj() { # METHOD PATH [JSON]
  printf 'header = "Authorization: token %s"\n' "$FORGEJO_SYNC_TOKEN" | curl -sS --fail-with-body --max-time 30 -K - -X "$1" \
    -H 'Content-Type: application/json' -H 'Accept: application/json' ${3:+--data "$3"} "$FORGEJO_URL/api/v1$2"
}
send_back() { # issue id, identifier, reason
  pc PATCH "/issues/$1" "$(jq -n --arg c "Changes requested: $3" '{status: "in_progress", comment: $c}')" >/dev/null \
    && log "$2: returned to its developer ($3)" || log "$2: could not return the issue"
}

pass() {
  issues=$(pc GET "/companies/$PAPERCLIP_COMPANY_ID/issues?status=in_review&limit=200") || { log "Paperclip not reachable"; return; }
  ids=$(printf '%s' "$issues" | jq -r '.[].id'); [ -n "$ids" ] || return
  repos=''
  for id in $ids; do
    # The list leaves the review stage out: read the issue itself.
    issue=$(pc GET "/issues/$id") || continue
    [ "$(printf '%s' "$issue" | jq -r '.executionState.currentStageType // ""')" = approval ] || continue
    ident=$(printf '%s' "$issue" | jq -r .identifier)
    # The branch carries the issue id, or the id of the issue this one continues.
    work=$(printf '%s' "$issue" | jq -r '(.description // "") | (capture("^Continues: (?<i>[A-Z]+-[0-9]+)") | .i) // empty'); work=${work:-$ident}
    [ -n "$repos" ] || repos=$(fj GET "/orgs/$FORGEJO_ORG/repos?limit=50" | jq -r '.[] | select(.archived | not) | .name') || { log "Forgejo not reachable"; return; }
    pr=''; repo=''
    for r in $repos; do
      # Newest first, so a reopened or replaced pull request wins over an old closed one.
      pr=$(fj GET "/repos/$FORGEJO_ORG/$r/pulls?state=all&sort=recentupdate&limit=50" \
        | jq -c --arg re "(^|/)$work(-|\$)" '[.[] | select(.head.ref | test($re))] | (map(select(.state == "open")) + map(select(.merged)))[0] // empty') || pr=''
      [ -z "$pr" ] || { repo="$FORGEJO_ORG/$r"; break; }
    done
    [ -n "$pr" ] || { log "$ident: waits for the owner but has no open or merged pull request"; continue; }
    n=$(printf '%s' "$pr" | jq -r .number); url=$(printf '%s' "$pr" | jq -r .html_url); sha=$(printf '%s' "$pr" | jq -r .head.sha)

    if [ "$(printf '%s' "$pr" | jq -r .merged)" = true ]; then
      by=$(printf '%s' "$pr" | jq -r '.merged_by.login // "the owner"')
      pc PATCH "/issues/$id" "$(jq -n --arg c "Approved: $url merged by $by." '{status: "done", comment: $c}')" >/dev/null \
        && log "$ident: closed, $url is merged" || log "$ident: $url is merged but the issue could not be closed"
      continue
    fi

    # The owner's own "request changes" on the current head.
    asked=$(fj GET "/repos/$repo/pulls/$n/reviews" | jq -c --arg u "$FORGEJO_OWNER_USER" --arg s "$sha" \
      '[.[] | select(.user.login == $u and .commit_id == $s and (.dismissed | not) and .state == "REQUEST_CHANGES")] | last // empty') || asked=''
    if [ -n "$asked" ]; then
      why=$(printf '%s' "$asked" | jq -r '.body // ""')
      send_back "$id" "$ident" "the owner asked for changes on $url${why:+: $why}"; continue
    fi

    # Forgejo computes "mergeable" in the background: act on a conflict only when three passes in a row saw it.
    if [ "$(printf '%s' "$pr" | jq -r .mergeable)" != true ]; then
      c=$(( $(cat "$STATE/$ident.conflict" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$STATE/$ident.conflict"
      [ "$c" -lt 3 ] || { rm -f "$STATE/$ident.conflict"; send_back "$id" "$ident" "$url conflicts with main: merge origin/main into the branch, resolve, and submit again"; }
      continue
    fi
    rm -f "$STATE/$ident.conflict"

    main=$(fj GET "/repos/$repo/branches/main" | jq -r .commit.id) || continue
    if [ "$(printf '%s' "$pr" | jq -r .merge_base)" != "$main" ] && [ ! -e "$STATE/$ident.$main.updated" ]; then
      # Once per (issue, main commit): if the update fails it is logged, not retried every pass.
      : > "$STATE/$ident.$main.updated"
      fj POST "/repos/$repo/pulls/$n/update?style=merge" >/dev/null \
        && log "$ident: $url updated with main (CI runs again; the owner approves and merges)" \
        || log "$ident: could not update $url with main"
    fi
  done
}

log "studio-sync started: every ${INTERVAL}s, org $FORGEJO_ORG, owner $FORGEJO_OWNER_USER"
while :; do pass; sleep "$INTERVAL"; done
