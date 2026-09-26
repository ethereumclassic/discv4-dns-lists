# discv4-dns-lists

DNS-based node lists for Ethereum Classic, published under three domains and
consumed by clients through [EIP-1459](https://eips.ethereum.org/EIPS/eip-1459)
discovery.

Each directory is one published tree, named after the DNS domain it serves.
`all.json` is the working node set the trees are filtered from.

| Domain | DNS provider | Trees |
|---|---|---|
| `ethereumclassic.net` | Cloudflare | `all.classic.` · `all.mordor.` |
| `ethclassic.net` | Cloudflare | `all.classic.` · `all.mordor.` |
| `ethereumclassic.network` | Cloudflare | `all.classic.` · `all.mordor.` |

**Three domains on one provider is not provider diversity.** A single Cloudflare
account problem removes every path at once. `devp2p` automates only Cloudflare
and Route53.

Adding a provider needs no client release and no change to `devp2p`: the
publisher is chosen per domain in `DOMAINS`, and the `txt` publisher renders a
tree to JSON for any external tool to push. Such a publisher must be
**incremental** — EIP-1459 records are content-addressed, so an unchanged node
keeps its record name and value and only genuine churn has to be written. A
delete-and-recreate rewrite of a ~180-record tree is ~360 operations and will
exceed a typical free-tier daily change budget on the first night.

## Why this repository exists

A client with no peers cannot sync, and the lists it starts from decide what its
first view of the chain is built on. Those lists should come from somewhere the
project controls and anyone can audit.

**This repository is the audit trail.** The signed DNS records are opaque to
whoever reads them; the node sets here are not. Anyone can diff what is committed
against what actually resolves in DNS, and every commit message carries the
published node count per tree, so a degraded publish is visible in `git log`
without diffing anything.

**It does not replace the other discovery paths, and must not.** Clients also
ship hardcoded bootnodes and other operators' DNS trees. More than one
independent publisher is the point: a client whose every discovery path traces to
one operator has the same exposure whoever that operator is.

## How the lists are produced

`scripts/update-lists.sh`, run by
[`update-dns-lists.yml`](.github/workflows/update-dns-lists.yml):

1. **Seed** from the DNS trees other operators already publish.
2. **Crawl.** `devp2p discv4 crawl` walks the DHT from the bootnodes the client
   itself ships, and **revalidates the seeded set** — every node is re-pinged; one
   that stops answering is dropped after a few missed checks, and a seeded node
   that never answers is dropped once no seed tree carries it.
3. **Filter.** `devp2p nodeset filter -eth-network classic|mordor` keeps nodes
   whose fork ID is anywhere on that network's fork schedule. The script then
   keeps only the nodes on its **current** fork ID — see
   [below](#only-nodes-on-the-current-fork-id-are-published).
4. **Cap** to the DNS zone budget, **sign** with the project key, **publish**,
   **commit** the result here.

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

**It also decides whether this is worth publishing at all.** Measured 2026-08-28:

| | seeded, 60-second crawl | unseeded, 40-minute crawl |
|---|---|---|
| classic | 340 | 44 |
| mordor | 11 | 3 |

An unseeded Mordor tree carries 3 nodes where the existing published tree carries
11 — a downgrade for anyone who switched to it. Seeded, this tree is a verified
superset instead.

The yield is low because the discv4 DHT is shared across networks: a crawl seeded
from ETC bootnodes still walks mostly non-ETC nodes, and `-eth-network` can only
match a node whose ENR carries an `eth` entry. Many do not.

**`devp2p` must be built from [`ethereumclassic/core-geth`](https://github.com/ethereumclassic/core-geth).**
Upstream go-ethereum's copy has no `classic` or `mordor` value for
`-eth-network` and **rejects them** — measured, exit 1 with
`-eth-network: unknown network "classic"`. A build from the wrong source
therefore fails the run rather than quietly publishing an empty tree.

## Only nodes on the current fork ID are published

**`-eth-network` admits every stage of the fork schedule, not only the current
one.** It is core-geth's `forkid.NewStaticFilter`, which judges
[EIP-2124](https://eips.ethereum.org/EIPS/eip-2124) compatibility from block
zero. From there every later stage looks like a node that is ahead, so any fork
ID on the network's schedule passes and only one off it is rejected.

**That admits nodes a new client cannot sync from.** A node that starts from an
empty chain advertises the genesis stage in its record until it imports its first
block, because the record is refreshed only on a new chain head and a snap sync
sets none until it finishes. Such a node answers every discovery ping, so it
ranks as fresh.
Measured 2026-09-25:

| classic | current `be46d57c` | genesis stage `fc64ec04` | before Spiral `7fd1bb25` |
|---|---|---|---|
| published tree, before this check | 46 | 73 | 1 |
| crawl set, before the cap | 139 | 279 | 2 |

A new node syncing Ethereum Classic mainnet that day dropped 8 distinct peers on
sync timeouts, and all 8 were in the genesis-stage group. That stage is also the
one Ethereum mainnet shares, so the record cannot say which chain such a node is
on.

**So the script keeps only nodes on `FORK_HASH_CLASSIC` or `FORK_HASH_MORDOR`**,
the fork hash a node at the chain head advertises, and it does so before the cap,
so the cap chooses among current nodes. Moving the filter's vantage point to the
chain head would not be enough: EIP-2124 also accepts a node that is behind when
its next fork matches, which is the genesis-stage case again.

**The values are pinned, and a pin goes stale at the next fork.** Before a
scheduled fork activates, nodes that announce it as their next fork and nodes
that do not yet know of it carry the same hash, and both are kept. Once any node
on the schedule advertises the hash that follows the pin, the script refuses to
publish and names the new value. The last published tree stays in DNS until the
pin is updated; the script never falls back to publishing the stage the network
has left.

## How large a tree is, and why

The cap comes from the DNS zone budget rather than from what the crawl happens
to find. A tree of N nodes costs N, plus one root record, plus about one branch
record per 11 nodes — measured against real signed trees at 11 nodes → 14
records and 150 → 165.

**Both trees share one budget, and discovery does not get all of it.** A
Cloudflare zone created on or after 2024-09-01 on the free plan holds **200
records** — for the whole zone, not per tree. The classic and mordor trees are
both in it, alongside the project's own services: mail records, the apex site,
and subdomains for explorers and dashboards. Whatever the zone already holds
counts against the same 200.

```
classic  120 nodes -> ~132 records
mordor    15 nodes ->  ~18 records   (actual yield is 11 -> 14; the cap is a ceiling)
                       ~150, leaving room for the domain's other services
```

**A tree's job is to reach the first few peers**, after which the discv4 DHT does
the work. Against three hardcoded bootnodes, 120 nodes is already a large
improvement, and the marginal value of node 300 is close to zero. Mordor's cap of
15 sits above an observed yield of 11 that has never been exceeded on any run
measured, so it is headroom rather than a constraint.

**No `snap.*` trees are published.** No core-geth path points snap discovery at
one on any network — `SnapDiscoveryURLs` is set equal to `EthDiscoveryURLs` at
every assignment site, and `SetDNSDiscoveryDefaults` hardcodes protocol `all`.
Publishing them would spend roughly 45% of the record budget on trees nothing
reads, which on a 200-record budget is the difference between 120 published
classic nodes and 65.

## Prior art: etclabscore/discv4-dns-lists

[`etclabscore/discv4-dns-lists`](https://github.com/etclabscore/discv4-dns-lists)
publishes the `blockd.info` and `etcdisco.net` trees and has run in production for
years. This repository is not a fork of it, but several things here come from
reading it.

**Adopted:** the sort by `lastResponse` then `score` before truncating, so the cap
keeps the freshest, best-scoring nodes rather than an arbitrary slice; and the
per-network cap itself, which exists because **Cloudflare limits records per
zone**.

**Not adopted, deliberately:** it publishes `les.*` trees. LES is being retired,
and both that repository and the Ethereum Foundation's currently publish **zero
nodes** into their `les.` trees.

**Where this repository differs:** it seeds from the existing published trees
before crawling, and it refuses to publish a tree that is empty, below an
absolute floor, or sharply smaller than the last one. Those checks are additions
for this deployment, not corrections to prior art.

The two also build their working set differently. That repository rebuilds
`all.json` from its own capped published trees before each crawl, so its size
reflects roughly one crawl's unfiltered reach rather than accumulated history.
This one seeds externally, from other operators' trees, and appends — which is
why a low cold-start yield here is not evidence of a broken crawl.

## Two checks stand between a bad crawl and DNS

**An absolute floor** per network, and **a relative one**: a tree that shrinks
below half of the last published count is refused. Neither alone is sufficient. A
floor high enough to catch a run that lost its seed trees would fail a legitimate
crawl-only run; one low enough to pass both would never fire.

The relative check compares against the last **committed** tree, which is why the
commit step matters as much as the publish step — without it there is no baseline
and the check cannot fire at all.

Both refuse rather than publish. A client reading a tree cannot tell a broken
crawl from a quiet network.

## Running it by hand

```bash
git clone https://github.com/ethereumclassic/core-geth.git /tmp/core-geth
cd /tmp/core-geth && go build -o /tmp/devp2p ./cmd/devp2p

cd /path/to/discv4-dns-lists
DEVP2P=/tmp/devp2p CORE_GETH_SRC=/tmp/core-geth ./scripts/update-lists.sh --dry-run
```

`--dry-run` crawls, filters and caps but neither signs nor publishes, and needs no
secrets. Use it to see what a crawl would produce before letting one reach DNS.

**A tree that will not sync locally is not necessarily dead.** `devp2p dns sync`
resolves through the system resolver and has no option to use another one. It
issues its lookups concurrently, and a stub resolver such as `systemd-resolved`
at `127.0.0.53` drops them under that concurrency while the same tree resolves
fine through a public resolver — a sync returning nothing, against `dig`
returning records normally, is the signature.

`dig @1.1.1.1 TXT <tree-root>` confirms the tree is alive, but it cannot repair
the sync: only the resolver the process itself uses decides that. Point the
system resolver at a public one, or run the command in a namespace with its own
`resolv.conf`, before concluding a tree is unreachable.

## Secrets

| Secret | Purpose |
|---|---|
| `DNS_SIGNING_KEY` | Ethereum **keystore JSON** for the key that signs the trees |
| `DNS_SIGNING_KEY_PASSWORD` | password for that keystore |
| `CLOUDFLARE_API_TOKEN` | token scoped to DNS edit on the Cloudflare zones |

Cloudflare **zone IDs** are not in that table on purpose. `devp2p` cannot find a
zone from a tree name, so each Cloudflare domain's zone ID is supplied through
`CLOUDFLARE_ZONE_IDS` as `domain=zoneid` pairs. A zone ID grants nothing on its
own and is shown in the provider's dashboard, so it travels as reviewable
configuration in the workflow rather than as a secret.

**The signing key is a keystore JSON, not a raw key.** `devp2p dns sign` loads it
with `keystore.DecryptKey` and reads the password from stdin; a raw hex key fails
with `error decrypting key`. That is why there are two secrets rather than one.

**Its public half is compiled into clients** as the `enrtree://<pubkey>@<domain>`
prefix in core-geth's `params/bootnodes_*.go`. Losing the private half means every
release carrying that prefix must be rebuilt to point at a new one. Treat it as a
long-lived project key, not a CI credential.

No key belongs in this repository in any form: `.gitignore` refuses `*.key` and
`*.pem`, and the workflow writes both halves to the runner's temp directory and
removes them in a step that runs even when the job fails.

## License

MIT. See [LICENSE](LICENSE).
