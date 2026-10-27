# Using the trees

This page lists the six discovery trees this repository publishes and shows how
to point a Core-Geth node at them.

## The trees

```
enrtree://APDLRZ2T7ERXPWXX4D5USB32NIFYHXMFVZQ3DZALK6JJJ5L4VSYIQ@all.classic.ethereumclassic.net
enrtree://APDLRZ2T7ERXPWXX4D5USB32NIFYHXMFVZQ3DZALK6JJJ5L4VSYIQ@all.classic.ethclassic.net
enrtree://APDLRZ2T7ERXPWXX4D5USB32NIFYHXMFVZQ3DZALK6JJJ5L4VSYIQ@all.classic.ethereumclassic.network
enrtree://APDLRZ2T7ERXPWXX4D5USB32NIFYHXMFVZQ3DZALK6JJJ5L4VSYIQ@all.mordor.ethereumclassic.net
enrtree://APDLRZ2T7ERXPWXX4D5USB32NIFYHXMFVZQ3DZALK6JJJ5L4VSYIQ@all.mordor.ethclassic.net
enrtree://APDLRZ2T7ERXPWXX4D5USB32NIFYHXMFVZQ3DZALK6JJJ5L4VSYIQ@all.mordor.ethereumclassic.network
```

`all.classic.` is Ethereum Classic and `all.mordor.` is its Mordor test network.
Each network's list is published under three domain names, and all six trees are
signed by one key, the text between `enrtree://` and `@`.

The same six URLs are compiled into Core-Geth, in
[`params/bootnodes_classic.go`](https://github.com/ethereumclassic/core-geth/blob/main/params/bootnodes_classic.go)
and
[`params/bootnodes_mordor.go`](https://github.com/ethereumclassic/core-geth/blob/main/params/bootnodes_mordor.go),
and each tree's directory in this repository records the one it serves in its
`enrtree-info.json`, so any copy of a URL can be checked against the others.

## Core-Geth v1.13.x

There is nothing to configure. Both networks read their three trees by default,
in every sync mode. Releases are published at
[`ethereumclassic/core-geth`](https://github.com/ethereumclassic/core-geth/releases/latest).

## Core-Geth v1.12.x

`--discovery.dns` points a node at other trees. Every `v1.12` release has it, and
so does any build of that code. Add it to the node's command line:

```sh
geth --classic --discovery.dns "enrtree://APDLRZ2T7ERXPWXX4D5USB32NIFYHXMFVZQ3DZALK6JJJ5L4VSYIQ@all.classic.ethereumclassic.net,enrtree://APDLRZ2T7ERXPWXX4D5USB32NIFYHXMFVZQ3DZALK6JJJ5L4VSYIQ@all.classic.ethclassic.net,enrtree://APDLRZ2T7ERXPWXX4D5USB32NIFYHXMFVZQ3DZALK6JJJ5L4VSYIQ@all.classic.ethereumclassic.network"
```

For Mordor, use `--mordor` and the three `all.mordor.` URLs. A node started from
a config file takes the same list under `[Eth]`:

```toml
[Eth]
EthDiscoveryURLs = [
  "enrtree://APDLRZ2T7ERXPWXX4D5USB32NIFYHXMFVZQ3DZALK6JJJ5L4VSYIQ@all.classic.ethereumclassic.net",
  "enrtree://APDLRZ2T7ERXPWXX4D5USB32NIFYHXMFVZQ3DZALK6JJJ5L4VSYIQ@all.classic.ethclassic.net",
  "enrtree://APDLRZ2T7ERXPWXX4D5USB32NIFYHXMFVZQ3DZALK6JJJ5L4VSYIQ@all.classic.ethereumclassic.network",
]
```

The list replaces the tree built into the release instead of adding to it. The
node needs no working bootnode to use it, because it dials the nodes in a tree
directly. To start from the bootnodes `v1.13.x` ships as well, pass them with
`--bootnodes`, which likewise replaces the built-in list; their addresses are in
the two `params` files linked above.

## If the trees do not resolve

[DNS hosting and outages](dns-outage.md#if-the-trees-stop-resolving) shows how to
start a node from the node records committed in this repository instead.
