# How the lists are built

This page covers the nightly pipeline behind the trees, the checks that stop a
bad crawl from reaching DNS, how a failed run is reported, and how to run it by
hand.

## The pipeline

[`scripts/update-lists.sh`](../scripts/update-lists.sh), run nightly by
[`update-dns-lists.yml`](../.github/workflows/update-dns-lists.yml), does four
things:

1. **Seed** from published trees: this repository's own, and the predecessor's
   for as long as they resolve.
2. **Crawl.** `devp2p discv4 crawl` walks the DHT from the bootnodes Core-Geth
   ships, and **revalidates the seeded set**. Every node is re-pinged; one that
   stops answering is dropped after a few missed checks, and a seeded node that
   never answers is dropped once no seed tree carries it.
3. **Filter.** `devp2p nodeset filter -eth-network classic|mordor` keeps nodes
   whose fork ID is anywhere on that network's fork schedule. The script then
   keeps only the nodes on its **current** fork ID, as
   [How nodes are chosen](node-selection.md#only-nodes-on-the-current-fork-id-are-published)
   describes.
4. **Cap** to the DNS zone budget, **sign** with the project key, **publish**, and
   **commit** the result here. Every commit message carries the node count of
   each tree, so a degraded publish shows in `git log` without diffing anything.

**Seeding is not trusting the other publishers.** Step 2 re-pings everything step
1 brought in, so a stale or hostile entry is not republished while live nodes
exist, and it is removed from the set as well. What seeding buys is reach;
verification still happens locally.

**A seeded node that never answers needs its own removal.** `devp2p` drops a node
whose score falls to zero, but skips rather than drops one that is at zero
already, which is where every seeded node starts. So a seed record that never
answers is pruned once no seed tree carries it, and only on a run where every
seed tree synced: a tree that failed may still carry it, and a run where the
syncs fail is more likely a resolver or network fault here than a verdict on the
records.

**Seeding also decides whether a tree is worth publishing at all.** Measured
2026-08-28, before the first publish:

| | seeded, 60-second crawl | unseeded, 40-minute crawl |
|---|---|---|
| classic | 340 | 44 |
| mordor | 11 | 3 |

Unseeded, a Mordor tree would have carried 3 nodes where the predecessor's carried
11, a downgrade for anyone who switched to it. Seeded, the crawl starts from
everything those trees carried and keeps what still answers.

The yield is low because the discv4 DHT is shared across networks: a crawl seeded
from ETC bootnodes still walks mostly non-ETC nodes, and `-eth-network` can only
match a node whose ENR carries an `eth` entry. Many do not.

**`devp2p` must be built from [`ethereumclassic/core-geth`](https://github.com/ethereumclassic/core-geth).**
Upstream go-ethereum's copy has no `classic` or `mordor` value for `-eth-network`
and **rejects them**: measured, it exits 1 with
`-eth-network: unknown network "classic"`. A build from the wrong source therefore
fails the run rather than quietly publishing an empty tree.

## Three checks stand between a bad crawl and DNS

The first two are **an absolute floor** per network and **a relative one**: a
tree that shrinks below half of the last published count is refused. Neither
alone is sufficient. A
floor high enough to catch a run that lost its seed trees would fail a legitimate
crawl-only run; one low enough to pass both would never fire.

The relative check compares against the last **committed** tree, which is why the
commit step matters as much as the publish step: without it there is no baseline,
and the check cannot fire at all.

**A retention check** catches the failure the other two cannot see. When the
runner itself loses the network, the crawl marks every node it cannot reach as
failing, but the cap still fills each tree from nodes that answered on earlier
runs, so no tree shrinks. So before anything is published, the run counts how
many of the last committed tree's nodes answered it, and refuses when fewer than
half did: a network does not lose half its reachable nodes overnight, but a
runner can lose its connection. Over the first sixteen nightlies, 111 to 119 of 120
classic nodes answered the next night, and mordor's worst night was 8 of 13. A
refused run commits nothing, so the scores it cut on nodes it could not reach are
discarded with it.

All three refuse rather than publish. A client reading a tree cannot tell a
broken crawl from a quiet network.

## A refusal is reported, not silent

GitHub's own notification for a scheduled run goes only to whoever last edited
the workflow's schedule. So **every scheduled run also rewrites one issue**,
labeled
[`pipeline-status`](https://github.com/ethereumclassic/discv4-dns-lists/issues?q=label%3Apipeline-status)
and opened by the workflow, with its result: the state, the last success and
failure, the consecutive-failure count and the latest failure's `ERROR` lines,
never the whole log. GitHub sends no notification for an edit, so the run also
**comments** on the issue when the state changes: on the first failure after a
success, and on the first success after failures. Subscribing to that one issue
is how to hear about exactly those, without a new issue or a notification every
night.

The issue is found by its label and its author, never its title, since anyone
can open an issue with a matching title. If the runner dies before the report
step runs, nothing is posted; the last-success date in the issue's title is what
shows the gap.

## Running it by hand

```bash
git clone https://github.com/ethereumclassic/core-geth.git /tmp/core-geth
cd /tmp/core-geth && go build -o /tmp/devp2p ./cmd/devp2p

cd /path/to/discv4-dns-lists
DEVP2P=/tmp/devp2p CORE_GETH_SRC=/tmp/core-geth ./scripts/update-lists.sh --dry-run
```

`--dry-run` crawls, filters and caps but neither signs nor publishes, and needs no
secrets. Use it to see what a crawl would produce before letting one reach DNS.
Seeding syncs every seed tree first, so the resolver limits under
[When a sync fails](verifying-a-tree.md#when-a-sync-fails) apply to a dry run as
well.

## Secrets

| Secret | Purpose |
|---|---|
| `DNS_SIGNING_KEY` | Ethereum **keystore JSON** for the key that signs the trees |
| `DNS_SIGNING_KEY_PASSWORD` | password for that keystore |
| `CLOUDFLARE_API_TOKEN` | token scoped to DNS edit on the Cloudflare zones |

**The secrets belong to the repository, not to a person.** They are stored as
GitHub Actions secrets of this repository in the
[`ethereumclassic`](https://github.com/ethereumclassic) organization, where more
than one maintainer holds admin rights and can rotate or replace them. GitHub
never displays a stored value, and each nightly commit names the workflow run that
signed and published it.

Cloudflare **zone IDs** are not in that table on purpose. `devp2p` cannot find a
zone from a tree name, so each Cloudflare domain's zone ID is supplied through
`CLOUDFLARE_ZONE_IDS` as `domain=zoneid` pairs. A zone ID grants nothing on its
own and is shown in the provider's dashboard, so it travels as reviewable
configuration in the workflow rather than as a secret.

**The signing key is a keystore JSON, not a raw key.** `devp2p dns sign` loads it
with `keystore.DecryptKey` and reads the password from stdin; a raw hex key fails
with `error decrypting key`. That is why there are two secrets rather than one.

**Its public half is compiled into clients** as the `enrtree://<pubkey>@<domain>`
prefix in Core-Geth's `params/bootnodes_*.go`. Losing the private half means every
release carrying that prefix must be rebuilt to point at a new one. Treat it as a
long-lived project key, not a CI credential.

No key belongs in this repository in any form: `.gitignore` refuses `*.key` and
`*.pem`, and the workflow writes both halves to the runner's temp directory and
removes them in a step that runs even when the job fails.
