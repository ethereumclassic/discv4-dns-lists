# How nodes are chosen

This page covers what gets a node into a tree, why a tree holds only nodes on the
network's current fork, and how large a tree can be.

## What gets a node listed

A node is published when it:

- answers the crawl's discovery pings from a reachable address,
- carries an `eth` entry in its node record with the network's current fork ID,
  and
- is among the 120 Classic or 15 Mordor such nodes that answered most recently,
  ranked by when they last answered and then by score.

The criteria are the same for every node, whoever runs it. The lists start a
node's search and do not choose its peers: after its first contacts, a node finds
further peers through the discovery network itself.

## Only nodes on the current fork ID are published

**`-eth-network` admits every stage of the fork schedule, not only the current
one.** It is Core-Geth's `forkid.NewStaticFilter`, which judges
[EIP-2124](https://eips.ethereum.org/EIPS/eip-2124) compatibility from block
zero. From there, every later stage looks like a node that is ahead, so any fork
ID on the network's schedule passes, and only one that is not on it is rejected.

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

**So [the script](../scripts/update-lists.sh) keeps only nodes on
`FORK_HASH_CLASSIC` or `FORK_HASH_MORDOR`**, the fork hash a node at the chain
head advertises, and it does so before the cap, so the cap chooses among current
nodes. Moving the filter's vantage point to the chain head would not be enough:
EIP-2124 also accepts a node that is behind when its next fork matches, which is
the genesis-stage case again.

**The values are pinned, and a pin goes stale at the next fork.** Before a
scheduled fork activates, nodes that announce it as their next fork and nodes
that do not yet know of it carry the same hash, and both are kept. Once any node
on the schedule advertises the hash that follows the pin, the script refuses to
publish and names the new value. The last published tree stays in DNS until the
pin is updated; the script never falls back to publishing the stage the network
has left.

## How large a tree is, and why

The cap comes from the DNS zone budget rather than from what the crawl happens
to find. A tree of N nodes costs N records, plus one for the root, plus about one
branch record per 11 nodes, measured against real signed trees at 11 nodes → 14
records and 150 → 165.

**Both trees share one budget, and discovery does not get all of it.** A
Cloudflare zone created on or after 2024-09-01 on the free plan holds **200
records** for the whole zone, not per tree. The classic and mordor trees are both
in it, alongside whatever else the domain serves, such as mail records, the apex
site and service subdomains, and all of it counts against the same 200.

```
classic  120 nodes -> ~132 records
mordor    15 nodes ->  ~18 records
                       ~150, leaving room for the domain's other services
```

**A tree's job is to reach the first few peers**, after which the discv4 DHT does
the work. Against three hardcoded bootnodes, 120 nodes is already a large
improvement, and the marginal value of node 300 is close to zero. Mordor's cap of
15 is headroom for a small network: its tree carries every current node the
crawl finds, up to the cap, and each night's count is in that night's commit
message.

**No `snap.*` trees are published.** No Core-Geth path points snap discovery at
one on any network: `SnapDiscoveryURLs` is set equal to `EthDiscoveryURLs` at
every assignment site, and `SetDNSDiscoveryDefaults` hardcodes protocol `all`.
Publishing them would spend roughly 45% of the record budget on trees nothing
reads, which on a 200-record budget is the difference between 120 published
classic nodes and 65.
