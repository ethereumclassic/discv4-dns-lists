# discv4-dns-lists

Publishes the Ethereum Classic [EIP-1459](https://eips.ethereum.org/EIPS/eip-1459)
DNS discovery trees. A crawl of the discv4 DHT is filtered per network, capped,
signed with the project key and written to DNS; the resulting node sets are
committed here as the public audit trail.

[README.md](README.md) explains *why* each design choice was made and is the
reference for the mechanism. This file is what an agent needs in order to work
here without breaking something.

**This repository is bootstrap infrastructure for a live network.** A bad publish
is not a failing build — it is clients that cannot find peers. Every rule below
about refusing, floors and confirmation exists for that reason.

## Stack

There is **no package manifest of any kind** in this repository — no
`package.json`, `go.mod`, `Cargo.toml`, `pyproject.toml`, `Makefile` or
equivalent. Nothing here is installed or built from a dependency declaration.
That absence is real; do not go looking for a manifest to update.

| Tool | Used for | Where it comes from |
|---|---|---|
| `bash` | `scripts/update-lists.sh` | system |
| `jq` | sorting and capping node sets | system |
| `python3` | seed merge, node counts, shrink baseline | system |
| `git` | committing published trees | system |
| `devp2p` | crawl, filter, sign, publish | **built from source, see below** |

**`devp2p` must be built from [`ethereumclassic/core-geth`](https://github.com/ethereumclassic/core-geth).**
Upstream go-ethereum's copy has no `classic` or `mordor` value for
`-eth-network` and rejects them with exit 1, so a build from the wrong source
fails the run rather than quietly publishing an empty tree. The Go version comes
from core-geth's own `go.mod`; this repository pins none.

## Commands

Every command below exists. There is **no `test`, `lint`, `build` or `fmt`
target of any kind**, because there is no task runner to define one in.

```bash
# Build the tool (required before anything else)
git clone https://github.com/ethereumclassic/core-geth.git /tmp/core-geth
cd /tmp/core-geth && go build -o /tmp/devp2p ./cmd/devp2p

# Dry run: crawls, filters and caps, but never signs or publishes.
# Needs no secrets. This is the safe way to see what a crawl would produce.
DEVP2P=/tmp/devp2p CORE_GETH_SRC=/tmp/core-geth ./scripts/update-lists.sh --dry-run
```

Exit codes: `0` published or dry run clean, `1` refused or failed, `2`
did-not-run (a required tool is missing).

### Checking the script

No linter or formatter is configured anywhere in this repository, and no CI job
runs one. Match the existing style by hand. If `shellcheck` is available, it is
worth running, but nothing gates on it:

```bash
bash -n scripts/update-lists.sh                     # parse check
shellcheck -S style scripts/update-lists.sh         # optional, not a gate
python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' \
  .github/workflows/update-dns-lists.yml            # workflow parse check
```

### Checking a published tree

`devp2p dns sync` uses the system resolver. A stub resolver such as
`systemd-resolved` at `127.0.0.53` times out under the query volume of a large
tree while that same tree resolves fine through a public resolver. **Re-query a
failed lookup with `dig @1.1.1.1` before concluding a tree is dead.** This has
been misread as a network fault more than once.

## Structure

```
scripts/update-lists.sh              # the whole pipeline: seed, crawl, filter, cap, sign, publish
.github/workflows/update-dns-lists.yml  # runs it; builds devp2p, handles secrets, commits results
all.json                             # working node set, unfiltered, cumulative across runs
all.<network>.<domain>/nodes.json    # one published tree per network per domain
```

The `all.*` directories are **generated output committed by the workflow**, not
hand-maintained source. Do not edit a `nodes.json` by hand.

## Domains

Three domains, all on Cloudflare.

| Domain | Provider | Publisher |
|---|---|---|
| `ethereumclassic.net` | Cloudflare | `devp2p dns to-cloudflare` |
| `ethclassic.net` | Cloudflare | `devp2p dns to-cloudflare` |
| `ethereumclassic.network` | Cloudflare | `devp2p dns to-cloudflare` |

**One provider is not provider diversity.** A single Cloudflare account problem
removes every ETC discovery path at once. Do not describe these trees as
provider-redundant.

**Each Cloudflare domain needs its zone ID.** `devp2p` resolves a zone by name
only when `--zoneid` is absent, and it passes the *tree* name to that lookup, so
it matches no zone and the publish fails. `CLOUDFLARE_ZONE_IDS` carries
`domain=zoneid` pairs; the script refuses before the crawl if one is missing. A
zone ID is not a credential and belongs in the workflow's env block, not its
secrets.

**Adding a provider needs no `devp2p` change and no client release.** It
automates Cloudflare and Route53 only, so anything else is published from
`to-txt` output by a script in this repository, selected per domain in
`DOMAINS`.

**Any such publisher must be incremental.** EIP-1459 records are
content-addressed, so an unchanged node keeps its record name and value and only
genuine churn needs writing. A delete-and-recreate rewrite of a ~180-record tree
is ~360 operations, which exceeds a typical free-tier daily change budget. The
`desec` branch is the shape this takes: it renders with `to-txt` and delegates
to `$DESEC_PUBLISHER`. No publisher is configured, so selecting that branch
fails rather than publishing.

## The numbers, and why they are what they are

Change none of these without reading the reasoning in `README.md` and in the
script's own comments first.

- **Caps** — `CAP_CLASSIC=120`, `CAP_MORDOR=15`. Derived from the DNS zone
  budget, not from crawl yield. A tree of N nodes costs N + 1 root + ~1 branch
  per 11 nodes, so 120 → ~132 records and 15 → ~18. A Cloudflare free-plan zone
  holds 200, and **discovery does not get all of it**: these domains also carry
  mail records, the apex site, and service subdomains, and whatever the zone
  already holds counts against the same 200. Raising a cap eats that headroom.
- **Floors** — `MIN_NODES_CLASSIC=40`, `MIN_NODES_MORDOR=5`. These are floors
  against a broken run, **not targets**. `MIN_NODES_MORDOR` is 5 against an
  observed 11 deliberately: Mordor's ceiling is the network, not the crawl, and
  a floor scaled from classic's numbers would refuse every legitimate Mordor
  publish.
- **Shrink tolerance** — 50% of the last *committed* tree. This is the only
  guard against a crawl that lost its seed trees and would otherwise replace a
  340-node tree with a healthy-looking 44-node one. It reads its baseline from
  `git show HEAD:<dir>/nodes.json`, **so the commit step is load-bearing**: if
  trees are never committed there is no baseline and the check cannot fire.

Both checks refuse rather than publish. A client reading a tree cannot tell a
broken crawl from a quiet network, so refusing is always the correct direction.

## Facts that mislead if you do not know them

- **The node set is cumulative.** `devp2p discv4 crawl` appends to an existing
  set rather than replacing it. One crawl sees one moment — a low cold-start
  yield is not a broken crawl.
- **Seeding is reach, not trust.** The pipeline seeds from other operators'
  published trees, then the crawl re-pings every seeded node and drops what does
  not answer. A stale or hostile entry is removed, not republished.
- **Only `all.*` trees are published.** No `snap.*` — no core-geth path points
  snap discovery at one on any network. No `les.*` — LES is being retired, and
  the publishers that still carry those trees publish zero nodes into them.
  Adding either spends the record budget on trees nothing reads.

## Dependency updates

**`.github/dependabot.yml` exists and version updates are deliberately off**
(`open-pull-requests-limit: 0`). Recorded 2026-08-31.

- **No ecosystem key can name a manifest here, because there is no manifest.**
  The only `package-ecosystem` that names something this repository actually
  holds is `github-actions`, for the SHA-pinned actions in the workflow.
- **The limit is zero because nobody is triaging a standing pull-request
  queue.** Two pinned actions is not a dependency surface that needs one.
- **Dependabot *security* updates are a repository setting with no key in that
  file.** Nothing in `dependabot.yml` turns them on or off, and a limit of zero
  does not withhold them. Confirm the repository setting's state rather than
  inferring it from the config.
- **What would change this:** the repository gaining a real manifest, or someone
  taking ownership of the queue. Raising the limit brings a `cooldown:` block
  with it; while the limit is zero a cooldown gates nothing and would read as a
  control that is operating.

Do not "fix" the disabled config into an active one. Its state is a decision.

## Boundaries

### Ask first

- **Any push, to any remote.** This is a public repository of the Ethereum
  Classic organization and it becomes bootstrap infrastructure for a live
  network. Nothing leaves the machine without explicit confirmation.
- **Any commit.** Including a commit that only touches documentation.
- **Enabling the nightly schedule.** The `schedule:` block in the workflow is
  commented out on purpose: until one supervised run has published and committed
  a tree, the shrink check has no baseline and cannot fire. Uncommenting it
  makes the *schedule*, not a supervised run, perform the first publish.
- **Changing a cap, a floor or the shrink tolerance.** See above.
- **Adding a domain, a DNS provider or a publisher.**
- **Changing anything under `.github/workflows/`.** These run in the
  organization's CI with the organization's secrets.

### Never

- **Commit a signing key, in any form, encrypted or not.** The key's public half
  is compiled into every client as the `enrtree://<pubkey>@<domain>` prefix;
  losing the private half means every release that shipped it must be rebuilt.
  It is a long-lived project key, not a CI credential. It lives only in the
  `DNS_SIGNING_KEY` secret and is written to runner temp, then removed in a step
  that runs even when the job fails.
- **Commit any credential**, DNS API token included.
- **Use `git add .` or `git add -A`.** Stage named paths. A run leaves untracked
  build output beside the trees it should commit.
- **Hand-edit a generated `nodes.json`.**
- **Add, change, or recommend changing `LICENSE`.** Licensing is the operator's
  and is a legal question before it is a technical one.
- **Publish a tree that failed a check.** Both checks refuse deliberately.

### Secrets the workflow expects

| Secret | Purpose |
|---|---|
| `DNS_SIGNING_KEY` | Ethereum **keystore JSON** for the tree-signing key |
| `DNS_SIGNING_KEY_PASSWORD` | password for that keystore |
| `CLOUDFLARE_API_TOKEN` | token scoped to DNS edit on the Cloudflare zones |

`devp2p dns sign` loads a keystore JSON with `keystore.DecryptKey` and reads the
password from **stdin**. A raw hex key fails with `error decrypting key`. That is
why there are two secrets and not one.

## Conventions

- **Verify by effect, and calibrate the check so it can fail.** A check that
  cannot report a negative proves nothing. This applies to gitignore coverage
  (`git check-ignore --no-index -q -- <path>`, never `-v` as the condition), to
  DNS lookups, and to any claim that something works.
- **Comments carry reasoning, not description.** The existing code explains why a
  number is what it is and what breaks if it changes. Match that.
- **Prefer refusing to guessing.** Every failure path in the pipeline exits
  rather than continuing with a degraded result.
- **Branching:** work lands on `main`. Inferred from history — the repository has
  a single branch and no recorded policy. Confirm before assuming it is settled.
