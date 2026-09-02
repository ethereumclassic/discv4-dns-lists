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
| `ethereumclassic.network` | deSEC | `all.classic.` · `all.mordor.` |

Two providers across three domains, so that no single provider outage removes
every path a client can use to bootstrap.

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
   itself ships, and **revalidates the seeded set** — every node is re-pinged, and
   what does not answer is dropped.
3. **Filter.** `devp2p nodeset filter -eth-network classic|mordor` keeps nodes
   whose fork ID matches.
4. **Cap** to the DNS zone budget, **sign** with the project key, **publish**,
   **commit** the result here.

**Seeding is not trusting the other publishers.** Step 2 re-pings everything step
1 brought in, so a stale or hostile entry is removed rather than republished.
What seeding buys is reach; verification still happens locally.

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

## How large a tree is, and why

The cap is derived from the smallest DNS zone budget rather than from what the
crawl happens to find.

Measured with `devp2p dns to-txt` against real signed trees, a published node
costs **~1.10 DNS records** at scale. A Cloudflare zone created on or after
2024-09-01 on the free plan holds **200 records**, which is the smallest budget
among the three domains, so it sets the shape for all of them and a client sees
the same set wherever it looks:

```
classic  150 nodes -> ~165 records
mordor    25 nodes -> ~32 records   (actual yield is 11; the cap is a ceiling)
                      ~197, inside 200
```

**A tree's job is to reach the first few peers**, after which the discv4 DHT does
the work. Against three hardcoded bootnodes, 150 nodes is already a large
improvement, and the marginal value of node 300 is close to zero.

**No `snap.*` trees are published.** No core-geth path points snap discovery at
one on any network — `SnapDiscoveryURLs` is set equal to `EthDiscoveryURLs` at
every assignment site, and `SetDNSDiscoveryDefaults` hardcodes protocol `all`.
Publishing them would spend roughly 45% of the record budget on trees nothing
reads, which on a 200-record budget is the difference between 150 published
classic nodes and 80.

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
before crawling, and it refuses to publish a tree that is empty, below an absolute
floor, or sharply smaller than the last one. The reference implementation crawls
from its own previous output and has no count check of any kind, so a failed crawl
there publishes whatever it managed to find.

**On accumulation, because the obvious reading is wrong.** It is tempting to
assume the reference's node set grows without bound — its `all.json` holds 11,707
entries. It does not. Its workflow rebuilds `all.json` from the capped published
trees before every crawl, so that figure is roughly **one 30-minute crawl's
unfiltered reach across all networks**, not years of accumulation. Measured across
8 consecutive runs it moves `9923 → 11803 → 9763 → 11628 → 10644 → 10701 → 9808
→ 11707` — down as often as up.

This repository does not condense: it seeds externally, from other operators'
trees, then appends. That is the real difference, and it is why a low cold-start
yield here is not evidence of a broken crawl.

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
uses the system resolver, and a stub resolver such as `systemd-resolved` at
`127.0.0.53` times out under the query volume of a large tree while the tree
resolves fine through a public resolver. Re-query a failed lookup with
`dig @1.1.1.1` before concluding anything.

## Secrets

| Secret | Purpose |
|---|---|
| `DNS_SIGNING_KEY` | Ethereum **keystore JSON** for the key that signs the trees |
| `DNS_SIGNING_KEY_PASSWORD` | password for that keystore |
| `CLOUDFLARE_API_TOKEN` | token scoped to DNS edit on the Cloudflare zones |

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
