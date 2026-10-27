# Why this repository exists

A client with no peers cannot sync, and the nodes it starts from shape its first
view of the chain. This repository publishes the lists core-geth starts from, in
place of the ones the ETC Cooperative maintained.

## The discovery endpoints v1.12.x starts from

The ETC Cooperative entered maintenance mode at the end of 2024, and its board has
communicated that it will dissolve.
[The ETC Cooperative transition](https://docs.coregeth.com/etc-cooperative-transition/)
lists where each of the services it maintained continues.

Core-geth `v1.12.x` starts from one DNS tree per network, published from
[`etclabscore/discv4-dns-lists`](https://github.com/etclabscore/discv4-dns-lists),
and from the bootnodes compiled into it. From `v1.12.20` to `v1.12.23` those are
the four Core-Geth `v1.12` bootnodes, three for Ethereum Classic and one for
Mordor, all with the same hosting provider. An attack in March 2026 repeatedly
crashed two of the three Classic bootnodes, as the
[March 2026 security audit](https://docs.coregeth.com/audits/2026-03-security-audit/)
records. The board has also communicated that the `v1.12` trees will stop being
updated as the ETC Cooperative dissolves. They will then serve an aging list of
nodes until their domains lapse and they stop resolving. Once those endpoints
are gone, a node on those releases that is new, or has been stopped for a while,
has nothing compiled in to start from.

## What replaces them

This repository and core-geth `v1.13.x` replace them from the community's
organization. The trees here are published under three domain names and rebuilt
every night. The bootnodes `v1.13.x` ships are run by the Core-Geth maintainers
and spread across hosting providers and countries. In `v1.13.0`, the three
Classic bootnodes are with Hetzner in Germany, OVH in the United States and
Contabo in Singapore, and the two Mordor bootnodes are with Hetzner in Finland and
OVH in the United States.

**A tree does not go stale the way a bootnode list does.** A client carries a
tree's URL, which names a domain and a signing key. The nodes behind it are
replaced every night as the crawl finds new ones and drops those that stop
answering, so a node that shuts down never needs a client release to route
around it.

**The pipeline runs in the open.** Its code, its configuration and every list it
has published are in this public repository of the organization, so more than one
maintainer can run it or move it, and anyone can read how it works and check what
it published.

## The predecessor: etclabscore/discv4-dns-lists

[`etclabscore/discv4-dns-lists`](https://github.com/etclabscore/discv4-dns-lists),
in the ETC Cooperative's `etclabscore` organization, is the source of the
`blockd.info` and `etcdisco.net` trees that core-geth `v1.12.x` reads, and it ran
in production for years. This repository was written separately rather than
forked from it, and several things here come from reading it.

**Adopted:** the sort by `lastResponse` then `score` before truncating, so the cap
keeps the freshest, best-scoring nodes rather than an arbitrary slice; and the
per-network cap itself, which exists because **Cloudflare limits records per
zone**.

**Not adopted, deliberately:** its `les.*` trees, for light clients. `v1.13.x`
reads the `all.*` trees in every sync mode, light included, so an `les.*` tree
here would spend records on a name no client asks for. Its `snap.*` trees are
left out for the reason given in
[How large a tree is](node-selection.md#how-large-a-tree-is-and-why).

**Where this repository differs:** it seeds from the existing published trees
before crawling, publishes only nodes on the current fork ID, and refuses to
publish a tree that is empty, below an absolute floor, or sharply smaller than the
last one, or any tree at all on a run where most of the last tree's nodes stopped
answering. Those checks are additions for this deployment, not corrections to
prior art.

The two also build their working set differently. That repository rebuilds
`all.json` from its own capped published trees before each crawl, so its size
reflects roughly one crawl's unfiltered reach rather than accumulated history.
This one seeds from published trees, its own included, and appends to what it
already holds, which is why a low cold-start yield here is not evidence of a
broken crawl.
