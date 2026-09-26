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

# When this run began, in the crawler's own timestamp format (UTC, whole
# seconds), so a node's lastResponse says whether it answered this run.
RUN_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)

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

# Refuse the whole run when fewer than this share of the nodes published last
# time answered this run's crawl. A network does not lose half its reachable
# nodes overnight; this runner's connection -- its network, its resolver, the
# host -- can, and a crawl that cannot reach the network marks every node as
# failing without shrinking the tree: the cap fills it from earlier runs, so
# neither the floor nor the shrink check sees anything wrong. Measured over the
# first sixteen nightlies, 111 to 119 of 120 classic nodes answered the next
# night's crawl, and mordor's worst night was 8 of 13.
RETENTION_MIN_PCT="${RETENTION_MIN_PCT:-50}"

# Per-network published-node cap, derived from the DNS zone budget rather than
# from crawl yield.
#
# A tree of N nodes costs N records, plus one root, plus about one branch per
# 11 nodes: 11 nodes -> 14 records, 120 -> 132.
#
# The budget is 200 records for a whole Cloudflare free-plan zone, and BOTH
# trees live in the same zone -- they are not budgeted separately. Discovery
# also shares that zone with the domain's other services: mail, the apex site,
# subdomains for explorers and dashboards, and whatever it already carries.
#
#   classic 120 -> ~132 records
#   mordor   15 ->  ~18 records  (actual yield is 11 -> 14; the cap is a ceiling)
#   both              ~150 of 200, leaving the rest for the domain's services
#
# A tree's job is to reach the first few peers, after which the discv4 DHT does
# the work. Against three hardcoded bootnodes, 120 nodes is already a large
# improvement and the marginal value of node 300 is close to zero. Mordor's cap
# sits above its observed yield of 11, so it is headroom rather than a limit.
CAP_CLASSIC="${CAP_CLASSIC:-120}"
CAP_MORDOR="${CAP_MORDOR:-15}"
cap_for() { case "$1" in classic) echo "$CAP_CLASSIC";; mordor) echo "$CAP_MORDOR";; *) echo 100;; esac; }

# The fork hash (EIP-2124 FORK_HASH) a synced node on each network advertises
# today. A published tree keeps only nodes whose record carries it.
#
# `nodeset filter -eth-network` does not do this. It is core-geth's
# forkid.NewStaticFilter, which judges compatibility from block zero, so every
# stage of the network's fork schedule passes -- the genesis stage included. A
# node that starts from an empty chain advertises the genesis stage until it
# imports its first block: its record is refreshed only on a new chain head, and
# a snap sync sets none until it finishes. Such a node answers every discovery
# ping and serves no blocks.
# Measured 2026-09-25, 73 of the 120 published classic nodes were on the genesis
# stage, which Ethereum mainnet shares, so the record cannot even say which
# chain such a node is on. The crawl held 139 classic nodes on this hash.
#
# Pinned, because nothing the pipeline runs can report a network's current fork
# ID: devp2p has no command for it, and the crawl never sees a chain head. A pin
# goes stale when the network passes its next fork, and a stale one would
# publish only the nodes left behind, so keep_current_fork refuses as soon as
# the crawl finds a node past it. Every stage's hash is listed in core-geth's
# core/forkid/forkid_test.go.
FORK_HASH_CLASSIC="${FORK_HASH_CLASSIC:-be46d57c}"   # since block 19,250,000 (Spiral)
FORK_HASH_MORDOR="${FORK_HASH_MORDOR:-3a6b00d7}"     # since block 9,957,000
fork_hash_for() { case "$1" in classic) echo "$FORK_HASH_CLASSIC";; mordor) echo "$FORK_HASH_MORDOR";; *) return 1;; esac; }

# domain:publisher pairs.
#
# All three domains are on Cloudflare. This is not provider diversity: one
# Cloudflare account problem removes every ETC discovery path at once.
#
# Adding a provider needs no devp2p change: render with `to-txt` and hand the
# result to an external publisher. Such a publisher must be incremental -- see
# publish_desec.
DOMAINS="${DOMAINS:-ethereumclassic.net:cloudflare ethclassic.net:cloudflare ethereumclassic.network:cloudflare}"

# Cloudflare zone IDs, as space-separated domain=zoneid pairs.
#
# devp2p cannot derive the zone. With --zoneid unset it looks up a zone named
# after the tree -- "all.classic.ethereumclassic.net" -- which matches no zone,
# and the publish fails with "zone could not be found".
#
# A zone ID is not a credential: it is visible in the provider dashboard and
# grants nothing on its own.
CLOUDFLARE_ZONE_IDS="${CLOUDFLARE_ZONE_IDS:-}"

zone_id_for() {
  local want="$1" pair
  for pair in $CLOUDFLARE_ZONE_IDS; do
    if [ "${pair%%=*}" = "$want" ]; then printf '%s\n' "${pair#*=}"; return 0; fi
  done
  return 1
}

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

# Seed the node set from published DNS trees, then let the crawl revalidate
# every one of them. This is not trusting the publishers: the crawl re-pings its
# input set, and a node that does not answer ranks behind every node that did,
# so a stale or hostile entry is not republished while live ones exist. Nor does
# it stay: a node that stops answering loses half its score per missed check and
# is dropped at zero, and a seeded node that has never answered is pruned in
# seed_from_trees once no seed tree carries it.
#
# It matters most on Mordor. Measured: a 15-minute crawl seeded from the single
# hardcoded Mordor bootnode matched 3 nodes, while the published trees carried
# 11 -- so a tree built from the crawl alone would be a downgrade for anyone who
# switched to it. Seeded this way, ours is a superset.
#
# This project's own trees are seeded first, so a run can rebuild from what it
# last published if the others stop resolving. Two domains rather than one,
# because a seed sync that fails is skipped silently and one zone should not be
# able to take the whole seed with it.
#
# The predecessor trees stay until this project runs its own bootnodes. They are
# currently the only thing replenishing Mordor -- the crawl has contributed zero
# Mordor nodes on every run measured -- so dropping them now would leave that
# tree decaying with nothing to refill it.
SEED_KEY_OURS="enrtree://APDLRZ2T7ERXPWXX4D5USB32NIFYHXMFVZQ3DZALK6JJJ5L4VSYIQ@"
SEED_KEY_PRIOR="enrtree://AJE62Q4DUX4QMMXEHCSSCSC65TDHZYSMONSD64P3WULVLSF6MRQ3K@"

SEED_TREES="${SEED_TREES:-\
${SEED_KEY_OURS}all.classic.ethereumclassic.net,\
${SEED_KEY_OURS}all.mordor.ethereumclassic.net,\
${SEED_KEY_OURS}all.classic.ethclassic.net,\
${SEED_KEY_OURS}all.mordor.ethclassic.net,\
${SEED_KEY_PRIOR}all.classic.blockd.info,\
${SEED_KEY_PRIOR}all.classic.etcdisco.net,\
${SEED_KEY_PRIOR}all.mordor.blockd.info,\
${SEED_KEY_PRIOR}all.mordor.etcdisco.net}"

count() { python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))))" "$1" 2>/dev/null || echo 0; }

seed_from_trees() {
  local out="$1" tmp merged=0 failed=0
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
      failed=$((failed + 1))
    fi
  done
  [ "$merged" -eq 0 ] && { log "no seed nodes obtained"; return 0; }
  python3 - "$out" "$tmp" "$failed" <<'PYEOF'
import json, os, sys
out, tmp, failed = sys.argv[1], sys.argv[2], int(sys.argv[3])
merged = json.load(open(out)) if os.path.exists(out) else {}
added, seeded = 0, set()
for root, _, files in os.walk(tmp):
    for f in files:
        if f != "nodes.json":
            continue
        for k, v in json.load(open(os.path.join(root, f))).items():
            seeded.add(k)
            if k not in merged:
                merged[k] = v
                added += 1

# The crawl never removes a node that has never answered it: devp2p halves a
# failing node's score and drops it at zero, but a node already at zero is
# skipped rather than dropped, so a seed record that never answers would stay
# forever. Prune it once no seed tree carries it -- but only on a run where
# every seed tree synced. A tree that failed may still carry it, and a run where
# the syncs fail is more likely a resolver or network fault here than a verdict
# on the records.
def never_answered(v):
    return not v.get("score") and str(v.get("lastResponse") or "0001").startswith("0001")

pruned = 0
if failed:
    print("  %d seed tree(s) unreachable: not pruning records that never answered" % failed)
else:
    for k in [k for k, v in merged.items() if k not in seeded and never_answered(v)]:
        del merged[k]
        pruned += 1
json.dump(merged, open(out, "w"), indent=2)
print("  merged %d new nodes from seed trees, pruned %d that never answered (set now %d)"
      % (added, pruned, len(merged)))
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
  local dir="$1" zone="$2"
  [ -n "${CLOUDFLARE_API_TOKEN:-}" ] || fail "CLOUDFLARE_API_TOKEN is unset"
  [ -n "$zone" ] || fail "no Cloudflare zone ID for $dir"
  # --zoneid must precede the directory: urfave/cli stops parsing flags at the
  # first positional argument, so a flag placed after it is silently ignored.
  "$DEVP2P" dns to-cloudflare --zoneid "$zone" "$dir" \
    || fail "cloudflare publish failed for $dir"
}

# Publish to deSEC via to-txt plus an external publisher.
#
# No domain selects this publisher today. It is the shape a second provider
# takes, and it fails rather than publishing if selected without
# DESEC_PUBLISHER set.
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

# Reduce a filtered node set, in place, to the nodes on the network's current
# fork hash -- see FORK_HASH_CLASSIC -- and refuse if the pin has gone stale.
#
# A fork hash is a CRC32 over the genesis hash and every fork block passed, so a
# node past the next fork F advertises crc32(F, pinned hash). F is read from the
# nodes that announce it as their `next`: in this set, and in the last committed
# tree, which still carries the announcement after the upgraded nodes have moved
# past it. The input has already been through `-eth-network`, so a successor
# counted here is on the schedule core-geth itself ships.
keep_current_fork() {
  local file="$1" net="$2" fork="$3" dir="$4"
  python3 - "$file" "$net" "$fork" "$dir" <(git show "HEAD:$dir/nodes.json" 2>/dev/null) <<'PYEOF'
import base64, collections, json, sys, zlib
path, net, want, label, committed = sys.argv[1:6]
want = want.lower()
var = "FORK_HASH_" + net.upper()
if len(want) != 8 or any(c not in "0123456789abcdef" for c in want):
    sys.exit("  ERROR: %s: %s=%s is not a fork hash -- expected 8 hex digits" % (label, var, want))

def item(b, i):
    # One RLP item at b[i]: (payload start, payload end).
    p = b[i]
    if p < 0x80: return i, i + 1
    if p < 0xb8: return i + 1, i + 1 + p - 0x80
    if p < 0xc0:
        s = i + 1 + p - 0xb7
        return s, s + int.from_bytes(b[i + 1:s], "big")
    if p < 0xf8: return i + 1, i + 1 + p - 0xc0
    s = i + 1 + p - 0xf7
    return s, s + int.from_bytes(b[i + 1:s], "big")

def items(b, start, end):
    out = []
    while start < end:
        s, e = item(b, start)
        out.append((s, e))
        start = e
    if start != end:
        raise ValueError("RLP list overruns its length")
    return out

def fork_id(nid, record):
    # The ENR is [signature, seq, key, value, ...]; the `eth` value is
    # [[fork hash, fork next], ...]. devp2p's own filter has already decoded
    # every record here, so a failure is this decoder's fault and must stop the
    # run rather than quietly drop the node.
    try:
        s = record[4:]
        raw = base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))
        top = items(raw, *item(raw, 0))
        for k, v in zip(top[2::2], top[3::2]):
            if raw[k[0]:k[1]] == b"eth":
                fid = items(raw, *items(raw, *v)[0])
                return raw[fid[0][0]:fid[0][1]].hex(), int.from_bytes(raw[fid[1][0]:fid[1][1]], "big")
    except Exception as e:
        sys.exit("  ERROR: %s: cannot decode the eth entry of node %s: %s" % (label, nid, e))
    sys.exit("  ERROR: %s: node %s has no eth entry, which -eth-network requires" % (label, nid))

nodes = json.load(open(path))
ids = {nid: fork_id(nid, v["record"]) for nid, v in nodes.items()}
try:
    prev = json.load(open(committed))
except ValueError:
    prev = {}   # no committed tree yet
prev_ids = [fork_id(nid, v["record"]) for nid, v in prev.items()]

announced = {nxt for h, nxt in list(ids.values()) + prev_ids if h == want and nxt}
successor = {"%08x" % zlib.crc32(f.to_bytes(8, "big"), int(want, 16)): f for f in announced}
past = collections.Counter(h for h, _ in ids.values() if h in successor)
if past:
    h, n = past.most_common(1)[0]
    sys.exit("  ERROR: %s: %d nodes advertise fork hash %s, the successor of %s=%s at block %d.\n"
             "  The network has passed that fork, and the pinned stage now holds only the nodes\n"
             "  left behind. Update %s to %s once that stage is confirmed canonical."
             % (label, n, h, var, want, successor[h], var, h))

kept = {nid: v for nid, v in nodes.items() if ids[nid][0] == want}
left = collections.Counter(ids[nid] for nid in nodes if nid not in kept)
print("  %s: %d of %d nodes on %s=%s; left out: %s" % (label, len(kept), len(nodes), var, want,
      ", ".join("%s next %d x%d" % (h, nx, c) for (h, nx), c in left.most_common()) or "none"))
if not kept:
    sys.exit("  ERROR: %s: no node carries %s=%s -- check it against core-geth's fork ID tests"
             % (label, var, want))
json.dump(kept, open(path, "w"), indent=2)
PYEOF
}

# Refuse if fewer than RETENTION_MIN_PCT of the nodes in the last committed tree
# answered this run -- see RETENTION_MIN_PCT. A node missing from the set counts
# as not answering. The first publish has no committed tree and is not checked.
check_retention() {
  local dir="$1"
  python3 - "$dir" "$RUN_START" "$RETENTION_MIN_PCT" all.json <(git show "HEAD:$dir/nodes.json" 2>/dev/null) <<'PYEOF'
import json, sys
label, start, pct, current, committed = sys.argv[1:6]
try:
    prev = json.load(open(committed))
except ValueError:
    print("  %s: no committed tree, nothing to compare against" % label)
    sys.exit(0)
now = json.load(open(current))
back = sum(1 for nid in prev if str(now.get(nid, {}).get("lastResponse") or "") >= start)
print("  %s: %d of the %d nodes published last time answered this run" % (label, back, len(prev)))
if prev and back * 100 < len(prev) * int(pct):
    sys.exit("  ERROR: %s: under %s%% of last time's nodes answered. A network does not lose half\n"
             "  its reachable nodes overnight; this runner's connection can." % (label, pct))
PYEOF
}

publish_tree() {
  local domain="$1" publisher="$2" src="$3" net="$4" min="$5" zone="$6"
  shift 6
  local dir="$domain"
  mkdir -p "$dir"
  "$DEVP2P" nodeset filter "$src" -eth-network "$net" "$@" > "$dir/nodes.raw.json" \
    || fail "filter failed for $domain"

  # Before the cap, so the cap chooses among current nodes only -- see
  # FORK_HASH_CLASSIC.
  local fork; fork=$(fork_hash_for "$net") || fail "$domain: no current fork hash for network '$net'"
  keep_current_fork "$dir/nodes.raw.json" "$net" "$fork" "$dir" \
    || fail "$domain: current-fork check failed -- refusing to publish"

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
  # 120-node tree with a 44-node one is a downgrade for everyone who switched to
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
    cloudflare) publish_cloudflare "$dir" "$zone" ;;
    desec)      publish_desec "$dir" ;;
    txt)        "$DEVP2P" dns to-txt "$dir" "$dir/records.txt.json" \
                  || fail "to-txt failed for $domain"
                log "$domain: rendered to $dir/records.txt.json, not published" ;;
    *)          fail "unknown publisher '$publisher' for $domain" ;;
  esac
  log "$domain: published via $publisher"
}

log "devp2p: $("$DEVP2P" --version 2>/dev/null || echo unknown)"

# Resolve every Cloudflare zone ID before the crawl rather than after it. A
# missing ID is a configuration error that cannot fix itself, and discovering it
# an hour into a run throws the crawl away -- on the nightly schedule that costs
# a full day. Dry runs never publish, so they do not need one.
if [ "$DRY_RUN" -eq 0 ]; then
  for entry in $DOMAINS; do
    case "${entry##*:}" in
      cloudflare)
        zone_id_for "${entry%%:*}" >/dev/null \
          || fail "no Cloudflare zone ID for ${entry%%:*}: set CLOUDFLARE_ZONE_IDS" ;;
    esac
  done
fi

# Seed first, so the crawl revalidates the seeded nodes rather than ignoring them.
seed_from_trees all.json

crawl classic "$BOOT_CLASSIC" all.json
crawl mordor  "$BOOT_MORDOR"  all.json
log "crawl set: $(count all.json) nodes total (both networks, unfiltered)"

# Before any tree is published, so a refusal never leaves one domain updated and
# the others not. A refused run commits nothing, so the scores this crawl cut on
# nodes it could not reach are discarded with it.
for entry in $DOMAINS; do
  domain="${entry%%:*}"
  for net in classic mordor; do
    check_retention "all.$net.$domain" \
      || fail "all.$net.$domain: most of last time's nodes did not answer -- refusing to publish anything"
  done
done

# Only `all.` trees are published. No core-geth path points snap discovery at a
# `snap.*` tree on any network -- SnapDiscoveryURLs is set equal to
# EthDiscoveryURLs at every assignment site, and SetDNSDiscoveryDefaults
# hardcodes protocol "all" -- and neither fukuii client reads them either. They
# would cost roughly 45% of the zone's record budget for nothing, which on a
# 200-record budget is the difference between 120 published classic nodes and 65.
for entry in $DOMAINS; do
  domain="${entry%%:*}"
  publisher="${entry##*:}"
  zone=""
  [ "$publisher" = cloudflare ] && zone=$(zone_id_for "$domain")
  publish_tree "all.classic.$domain" "$publisher" all.json classic "$MIN_NODES_CLASSIC" "$zone"
  publish_tree "all.mordor.$domain"  "$publisher" all.json mordor  "$MIN_NODES_MORDOR"  "$zone"
done

log "done"
