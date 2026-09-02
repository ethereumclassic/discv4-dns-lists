#!/usr/bin/env bash
#
# Crawl the Ethereum Classic DHT, filter the result per network, sign each DNS
# discovery tree and publish it to that domain's provider.
#
# Run from the repository root. Requires devp2p built from ethereumclassic/core-geth:
# upstream go-ethereum's devp2p has no "classic" or "mordor" value for -eth-network,
# and rejects them outright -- see the note on the filter step below.
#
#   DEVP2P=/path/to/devp2p \
#   DNS_SIGNING_KEY_FILE=/path/to/keystore.json \
#   DNS_SIGNING_KEY_PASSWORD_FILE=/path/to/password.txt \
#   CLOUDFLARE_API_TOKEN=... \
#   ./scripts/update-lists.sh [--dry-run]
#
# Exit 0 published (or dry run clean), 1 refused or failed, 2 did-not-run.

set -uo pipefail

DEVP2P="${DEVP2P:-devp2p}"
CRAWL_TIMEOUT="${CRAWL_TIMEOUT:-30m}"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# A crawl that returns almost nothing is a broken crawl, not a small network.
# Publishing its result would replace a working tree with a dead one, and the
# clients that read it have no way to tell the difference. Refuse instead.
#
# These are floors against a broken run, NOT targets. Measured 2026-08-28: a
# seeded 60-second crawl yields 340 classic and 11 mordor; unseeded over 40
# minutes it yields 44 and 3. So the classic floor sits above the unseeded
# figure, to catch a run that lost its seed trees.
#
# MIN_NODES_MORDOR is 5 against an observed 11 deliberately -- Mordor's ceiling
# is the network, not the crawl, and a floor scaled from classic's numbers would
# refuse every legitimate Mordor publish.
MIN_NODES_CLASSIC="${MIN_NODES_CLASSIC:-40}"
MIN_NODES_MORDOR="${MIN_NODES_MORDOR:-5}"

# Refuse a published tree that shrinks below this fraction of the last one.
SHRINK_TOLERANCE_PCT="${SHRINK_TOLERANCE_PCT:-50}"

# Per-network published-node cap, derived from the smallest DNS zone budget
# rather than from what the crawl happens to find.
#
# Measured with `devp2p dns to-txt` against real signed trees: a published node
# costs ~1.10 DNS records at scale, ~1.27 on a very small tree where the fixed
# root and branch records have not amortized. A Cloudflare zone created on or
# after 2024-09-01 on the free plan holds 200 records, and that is the smallest
# budget among our three domains -- so it sets the shape for all of them, and a
# client sees the same set wherever it looks.
#
#   classic 150 -> ~165 records
#   mordor   25 -> ~32 records  (actual yield is 11; the cap is a ceiling)
#   total       -> ~197, inside 200
#
# A tree's job is to reach the first few peers, after which the discv4 DHT does
# the work. Against three hardcoded bootnodes, 150 nodes is already a large
# improvement and the marginal value of node 300 is close to zero.
CAP_CLASSIC="${CAP_CLASSIC:-150}"
CAP_MORDOR="${CAP_MORDOR:-25}"
cap_for() { case "$1" in classic) echo "$CAP_CLASSIC";; mordor) echo "$CAP_MORDOR";; *) echo 100;; esac; }

# domain:publisher pairs. Three domains across two providers, so that no single
# provider outage removes every ETC discovery path.
#
# `devp2p dns` automates Cloudflare only among these; deSEC is published from
# `to-txt` output by an external, diff-based publisher -- see publish_desec.
DOMAINS="${DOMAINS:-ethereumclassic.net:cloudflare ethclassic.net:cloudflare ethereumclassic.network:desec}"

log()  { printf '  %s\n' "$*"; }
fail() { printf '  ERROR: %s\n' "$*" >&2; exit 1; }

# Preflight every external command this script depends on. python3 is as load
# bearing as jq here -- it merges the seed set, counts nodes, and reads the
# shrink-check baseline -- and its absence would otherwise make the seed merge a
# silent no-op rather than a failure.
for tool in "$DEVP2P" jq python3; do
  command -v "$tool" >/dev/null 2>&1 || [ -x "$tool" ] || { echo "DID-NOT-RUN: $tool not found" >&2; exit 2; }
done

# Bootstrap set, read from the client rather than copied here. A second copy of
# a bootnode list is a second thing to go stale, and this one would go stale
# silently -- a dead entry just makes the crawl start slower, never louder.
#
# CORE_GETH_SRC must point at a core-geth checkout; the workflow uses the same
# one it builds devp2p from, so the crawl is always seeded by the list the
# client itself ships.
extract_bootnodes() {
  local file="$1"
  [ -f "$file" ] || fail "no bootnode source at $file"
  grep -oE '"enode://[^"]+"' "$file" | tr -d '"' | paste -sd,
}

CORE_GETH_SRC="${CORE_GETH_SRC:-}"
if [ -n "$CORE_GETH_SRC" ]; then
  BOOT_CLASSIC=$(extract_bootnodes "$CORE_GETH_SRC/params/bootnodes_classic.go")
  BOOT_MORDOR=$(extract_bootnodes "$CORE_GETH_SRC/params/bootnodes_mordor.go")
else
  BOOT_CLASSIC=""
  BOOT_MORDOR=""
fi

# An explicit override wins, for a one-off crawl from a known-good seed.
[ -n "${CLASSIC_BOOTNODES:-}" ] && BOOT_CLASSIC="$CLASSIC_BOOTNODES"
[ -n "${MORDOR_BOOTNODES:-}" ]  && BOOT_MORDOR="$MORDOR_BOOTNODES"

[ -n "$BOOT_CLASSIC" ] || fail "no classic bootnodes: set CORE_GETH_SRC or CLASSIC_BOOTNODES"
[ -n "$BOOT_MORDOR" ]  || fail "no mordor bootnodes: set CORE_GETH_SRC or MORDOR_BOOTNODES"
log "seeded from $(tr ',' '\n' <<<"$BOOT_CLASSIC" | wc -l) classic and $(tr ',' '\n' <<<"$BOOT_MORDOR" | wc -l) mordor bootnodes"

# Seed the node set from the DNS trees other operators already publish, then let
# the crawl revalidate every one of them. This is not trusting their lists: the
# crawl re-pings its input set and drops what does not answer, so a hostile or
# stale entry is removed rather than republished.
#
# It matters most on Mordor. Measured 2026-08-28: a 15-minute crawl seeded from
# the single hardcoded Mordor bootnode matched 3 nodes, while the existing
# published tree carried 11 -- so a tree built from the crawl alone would be a
# downgrade for anyone who switched to it. Seeded this way, ours is a superset.
SEED_TREES="${SEED_TREES:-enrtree://AJE62Q4DUX4QMMXEHCSSCSC65TDHZYSMONSD64P3WULVLSF6MRQ3K@all.classic.blockd.info,enrtree://AJE62Q4DUX4QMMXEHCSSCSC65TDHZYSMONSD64P3WULVLSF6MRQ3K@all.classic.etcdisco.net,enrtree://AJE62Q4DUX4QMMXEHCSSCSC65TDHZYSMONSD64P3WULVLSF6MRQ3K@all.mordor.blockd.info,enrtree://AJE62Q4DUX4QMMXEHCSSCSC65TDHZYSMONSD64P3WULVLSF6MRQ3K@all.mordor.etcdisco.net}"

count() { python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))))" "$1" 2>/dev/null || echo 0; }

seed_from_trees() {
  local out="$1" tmp merged=0
  [ -n "$SEED_TREES" ] || { log "no seed trees configured"; return 0; }
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  local url
  for url in ${SEED_TREES//,/ }; do
    local dir
    dir="$tmp/$(echo "$url" | tr -c 'a-zA-Z0-9' '_')"
    # A tree that will not sync is skipped, never fatal: these are other
    # people's infrastructure and the crawl proceeds without them.
    if "$DEVP2P" dns sync "$url" "$dir" >/dev/null 2>&1; then
      local n; n=$(count "$(find "$dir" -name nodes.json | head -1)")
      log "seed tree ${url##*@}: $n nodes"
      merged=$((merged + n))
    else
      log "seed tree ${url##*@}: unreachable, skipping"
    fi
  done
  [ "$merged" -eq 0 ] && { log "no seed nodes obtained"; return 0; }
  python3 - "$out" "$tmp" <<'PYEOF'
import json, os, sys
out, tmp = sys.argv[1], sys.argv[2]
merged = json.load(open(out)) if os.path.exists(out) else {}
added = 0
for root, _, files in os.walk(tmp):
    for f in files:
        if f != "nodes.json":
            continue
        for k, v in json.load(open(os.path.join(root, f))).items():
            if k not in merged:
                merged[k] = v
                added += 1
json.dump(merged, open(out, "w"), indent=2)
print("  merged %d new nodes from seed trees (set now %d)" % (added, len(merged)))
PYEOF
}

crawl() {
  local net="$1" boot="$2" out="$3"
  log "crawling $net (timeout $CRAWL_TIMEOUT)"
  # crawl appends to an existing node set, so a prior run's nodes survive a
  # single bad crawl rather than being replaced by it.
  "$DEVP2P" discv4 crawl -bootnodes "$boot" -timeout "$CRAWL_TIMEOUT" "$out" \
    || fail "crawl failed for $net"
}

# Publish a signed tree directory to Cloudflare. The API token is read from the
# CLOUDFLARE_API_TOKEN environment variable, which devp2p's --token flag already
# declares as its EnvVar -- passing it on the command line as well would put the
# token into /proc/<pid>/cmdline for no gain.
publish_cloudflare() {
  local dir="$1"
  [ -n "${CLOUDFLARE_API_TOKEN:-}" ] || fail "CLOUDFLARE_API_TOKEN is unset"
  "$DEVP2P" dns to-cloudflare "$dir" || fail "cloudflare publish failed for $dir"
}

# Publish to deSEC via to-txt plus an external publisher.
#
# deSEC allows 300 RRset changes per domain per day. A ~180-record tree
# republished by delete-and-recreate is ~360 operations, so it would fail on the
# first night and every night after. EIP-1459 records are content-addressed, so
# an unchanged node keeps its record name and value -- the publisher MUST be
# diff-based and write only genuine churn. DNSControl and octoDNS both are, and
# DNSControl ships a deSEC provider documenting this exact limit.
publish_desec() {
  local dir="$1" txt
  txt="$dir/records.txt.json"
  "$DEVP2P" dns to-txt "$dir" "$txt" || fail "to-txt failed for $dir"
  log "$dir: rendered $(jq 'length' "$txt" 2>/dev/null || echo '?') TXT records"
  [ -n "${DESEC_PUBLISHER:-}" ] \
    || fail "DESEC_PUBLISHER is unset: no diff-based publisher configured for $dir"
  [ -x "$DESEC_PUBLISHER" ] || fail "DESEC_PUBLISHER is not executable: $DESEC_PUBLISHER"
  "$DESEC_PUBLISHER" "$dir" "$txt" || fail "desec publish failed for $dir"
}

publish_tree() {
  local domain="$1" publisher="$2" src="$3" net="$4" min="$5"
  shift 5
  local dir="$domain"
  mkdir -p "$dir"
  "$DEVP2P" nodeset filter "$src" -eth-network "$net" "$@" > "$dir/nodes.raw.json" \
    || fail "filter failed for $domain"

  # Cap the published set against the DNS zone budget -- see CAP_CLASSIC above.
  #
  # Sort before truncating, so the cap keeps the freshest and best-scoring nodes
  # rather than an arbitrary slice: `lastResponse` is when the node last answered,
  # `score` is the crawler's own confidence. Adopted from
  # etclabscore/discv4-dns-lists, which hit the Cloudflare limit in production.
  local cap; cap=$(cap_for "$net")
  jq 'to_entries
      | sort_by(.value.lastResponse, .value.score)
      | reverse
      | .['"0:$cap"']
      | from_entries' "$dir/nodes.raw.json" > "$dir/nodes.json" \
    || fail "sort/cap failed for $domain"
  rm -f "$dir/nodes.raw.json"

  local n; n=$(count "$dir/nodes.json")

  # Two checks, because a fixed floor alone cannot tell a broken run from a
  # degraded one. A floor set high enough to catch a lost-seed run would fail a
  # legitimate crawl-only run, and one set low enough to pass both never fires.
  if [ "$n" -lt "$min" ]; then
    fail "$domain: $n nodes is below the absolute floor of $min -- refusing to publish"
  fi

  # The relative check is the one that matters after the first run: replacing a
  # 150-node tree with a 44-node one is a downgrade for everyone who switched to
  # it, even though 44 is a healthy crawl-only result.
  # Compare against the last COMMITTED tree, not the working file, which this
  # run has already overwritten.
  local prev
  prev=$(git show "HEAD:$dir/nodes.json" 2>/dev/null | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)
  if [ "$prev" -gt 0 ]; then
    local floor_rel=$(( prev * SHRINK_TOLERANCE_PCT / 100 ))
    if [ "$n" -lt "$floor_rel" ]; then
      fail "$domain: $n nodes is under $SHRINK_TOLERANCE_PCT% of the $prev last published -- refusing to publish"
    fi
    log "$domain: $n nodes (last published $prev)"
  else
    log "$domain: $n nodes (first publish)"
  fi

  [ "$DRY_RUN" -eq 1 ] && { log "$domain: dry run, not signing or publishing"; return 0; }

  # devp2p's `dns sign` loads an Ethereum keystore JSON and reads its password
  # from stdin -- it does not accept a raw hex key. Both halves are required.
  [ -n "${DNS_SIGNING_KEY_FILE:-}" ] || fail "DNS_SIGNING_KEY_FILE is unset"
  [ -n "${DNS_SIGNING_KEY_PASSWORD_FILE:-}" ] || fail "DNS_SIGNING_KEY_PASSWORD_FILE is unset"
  [ -f "$DNS_SIGNING_KEY_FILE" ] || fail "no signing key at $DNS_SIGNING_KEY_FILE"
  [ -f "$DNS_SIGNING_KEY_PASSWORD_FILE" ] || fail "no key password at $DNS_SIGNING_KEY_PASSWORD_FILE"
  "$DEVP2P" dns sign "$dir" "$DNS_SIGNING_KEY_FILE" -domain "$domain" \
    < "$DNS_SIGNING_KEY_PASSWORD_FILE" \
    || fail "sign failed for $domain"

  case "$publisher" in
    cloudflare) publish_cloudflare "$dir" ;;
    desec)      publish_desec "$dir" ;;
    txt)        "$DEVP2P" dns to-txt "$dir" "$dir/records.txt.json" \
                  || fail "to-txt failed for $domain"
                log "$domain: rendered to $dir/records.txt.json, not published" ;;
    *)          fail "unknown publisher '$publisher' for $domain" ;;
  esac
  log "$domain: published via $publisher"
}

log "devp2p: $("$DEVP2P" --version 2>/dev/null || echo unknown)"

# Seed first, so the crawl revalidates the seeded nodes rather than ignoring them.
seed_from_trees all.json

crawl classic "$BOOT_CLASSIC" all.json
crawl mordor  "$BOOT_MORDOR"  all.json
log "crawl set: $(count all.json) nodes total (both networks, unfiltered)"

# Only `all.` trees are published. No core-geth path points snap discovery at a
# `snap.*` tree on any network -- SnapDiscoveryURLs is set equal to
# EthDiscoveryURLs at every assignment site, and SetDNSDiscoveryDefaults
# hardcodes protocol "all" -- and neither fukuii client reads them either. They
# would cost roughly 45% of the zone's record budget for nothing, which on a
# 200-record budget is the difference between 150 published classic nodes and 80.
for entry in $DOMAINS; do
  domain="${entry%%:*}"
  publisher="${entry##*:}"
  publish_tree "all.classic.$domain" "$publisher" all.json classic "$MIN_NODES_CLASSIC"
  publish_tree "all.mordor.$domain"  "$publisher" all.json mordor  "$MIN_NODES_MORDOR"
done

log "done"
