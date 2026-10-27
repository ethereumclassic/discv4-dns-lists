# Verifying a tree

A client checks every record it downloads against the key in the tree's URL. The
commands below make the same check by hand, and compare what DNS serves with what
this repository recorded when the tree was published.

## Compare a tree with this repository

`devp2p`, in Core-Geth's `alltools` archive, verifies each record as it downloads
it and writes out the list it verified. From a clone of this repository:

```bash
devp2p dns sync --timeout 30s \
  enrtree://APDLRZ2T7ERXPWXX4D5USB32NIFYHXMFVZQ3DZALK6JJJ5L4VSYIQ@all.classic.ethereumclassic.net live
diff <(jq -r 'keys[]' live/nodes.json | sort) \
     <(jq -r 'keys[]' all.classic.ethereumclassic.net/nodes.json | sort) && echo "same nodes"
```

`diff` compares the node IDs served in DNS with the ones committed here, so pull
first. Keep the output directory (`live` above): without one, `devp2p` writes into
a directory named after the tree, which in this repository is the committed copy.

## Check the sequence number

A quicker check: the `seq=` value in
`dig +short TXT all.classic.ethereumclassic.net @1.1.1.1` matches `seq` in that
directory's `enrtree-info.json`. Both can trail a publish briefly, since the
commit lands a few minutes after the records and resolvers can keep the old root
for up to 30 minutes.

## When a sync fails

**A tree that will not sync is not necessarily unreachable.** `devp2p dns sync`
resolves through the system resolver and has no option to use another one. It
fetches one record at a time, at most three a second, and gives each lookup five
seconds unless `--timeout` sets a longer limit, with no retry, so a single slow
answer fails the whole sync. A stub resolver such as `systemd-resolved` at
`127.0.0.53` has been measured failing it outright while the same tree resolves
fine through a public resolver. A sync that returns nothing while `dig` returns
records normally is the sign of it.

`dig @1.1.1.1 TXT <tree-root>` confirms a tree is alive, but it cannot repair the
sync, because only the resolver the process itself uses decides that. Point the
system resolver at a public one, or run the command in a namespace with its own
`resolv.conf`, before concluding a tree is unreachable.
