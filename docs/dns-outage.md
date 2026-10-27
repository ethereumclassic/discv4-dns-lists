# DNS hosting and outages

This page covers how the trees are served, what a problem with their DNS would
and would not affect, and how a node and the trees themselves recover from one.

## How the trees are served

All three domains are served from one Cloudflare account, on Cloudflare's free
plan, which includes DNS at no charge. Route53, the other provider `devp2p`
publishes to directly, charges for each hosted zone every month and for every
query it answers, so its cost would grow with the number of nodes reading the
trees.

Serving each list under three names keeps it reachable through a problem with any
one name, such as a lapsed registration or a broken zone. A problem with the
account itself would take all six trees offline together, until the domains were
moved to another DNS host.

Every record is signed with the project key, which is held separately from the
DNS account. A client accepts only records that verify against that key, so
control of a zone is enough to withhold a tree or to serve an older version of it,
and not enough to put other nodes in it.

## If the trees stop resolving

The nodes remain reachable. Each tree is committed here exactly as it was
published, so its node records are available from this repository whether or not
DNS is answering. A node that is already running keeps its peers and goes on
finding more through the discovery network, and the bootnodes compiled into
Core-Geth `v1.13.x` do not use DNS at all.

A node that cannot find peers can start from the committed records instead. This
takes the twenty Classic nodes that answered most recently and passes them to the
node as bootnodes:

```bash
geth --classic --bootnodes "$(curl -fsSL https://raw.githubusercontent.com/ethereumclassic/discv4-dns-lists/main/all.classic.ethereumclassic.net/nodes.json \
  | jq -r '[to_entries | sort_by(.value.lastResponse) | reverse | .[:20][] | .value.record] | join(",")')"
```

For Mordor, use `--mordor` and `all.mordor.ethereumclassic.net`. The same file can
be read from a clone of this repository. Every `v1.12` and `v1.13` release accepts
these `enr:` records as bootnodes. The flag replaces the built-in list, and a
malformed entry stops the node from starting, so pass the list as the command
produces it.

## Bringing the trees back

Bringing the trees back needs no client release and no signing key. Each tree's
directory here holds the tree as it was last signed, so once the domains point at
another DNS host, `devp2p dns to-route53`, or `to-cloudflare` for a new account,
redeploys it as it stands, and clients find it at the same URLs. Only the next
nightly refresh needs the key.

The publisher is chosen per domain in `DOMAINS`: `devp2p` drives Cloudflare and
Route53 directly, and the `txt` publisher renders a tree as JSON for any other
provider's tooling to push. Such a publisher must be **incremental**. EIP-1459
records are content-addressed, so an unchanged node keeps its record name and
value and only genuine churn has to be written. Deleting and recreating every
record instead costs two operations per record each night, about 300 for a domain
carrying both trees, which exceeds a typical free-tier daily change budget.
