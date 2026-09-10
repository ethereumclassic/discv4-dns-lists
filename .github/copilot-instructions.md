# Copilot Instructions: discv4-dns-lists

<!--
  SELF-CONTAINED, deliberately. This repository is public, so its audience is
  not one person's toolchain, and several Copilot surfaces -- github.com Chat,
  VS Code code review, and the Chat and code-review surfaces of Visual Studio,
  JetBrains, Eclipse and Xcode -- do not read AGENTS.md at all. On those, this
  file is the only instruction the model sees, so a thin pointer would leave it
  with nothing.

  The cost of that choice is duplication with AGENTS.md. Pay it deliberately:
  when either file changes, change both. Do not let the two contradict each
  other -- wherever a surface reads both, both are supplied to the model.
-->

## Project

Publishes the Ethereum Classic [EIP-1459](https://eips.ethereum.org/EIPS/eip-1459)
DNS discovery trees. A crawl of the discv4 DHT is filtered per network, capped,
signed with the project key and written to DNS; the node sets are committed here
as the public audit trail.

**This is bootstrap infrastructure for a live network.** A bad publish is not a
failing build — it is clients that cannot find peers.

## Stack

There is **no package manifest of any kind** here: no `package.json`, `go.mod`,
`Cargo.toml`, `pyproject.toml` or `Makefile`. Nothing is installed from a
dependency declaration. Do not look for a manifest to update, and do not
suggest adding one.

- `bash` — `scripts/update-lists.sh`, the whole pipeline
- `jq` — sorting and capping node sets
- `python3` — seed merge, node counts, shrink baseline
- `devp2p` — **built from `ethereumclassic/core-geth`**, not from upstream
  go-ethereum, whose copy has no `classic` or `mordor` value for `-eth-network`
  and rejects them with exit 1

## Commands

Every command below exists. There is **no `test`, `lint`, `build` or `fmt`
target**, because there is no task runner to define one in. Do not invent a call
to one.

```bash
# Build the tool
git clone https://github.com/ethereumclassic/core-geth.git /tmp/core-geth
cd /tmp/core-geth && go build -o /tmp/devp2p ./cmd/devp2p

# Dry run: crawls, filters and caps; never signs or publishes; needs no secrets
DEVP2P=/tmp/devp2p CORE_GETH_SRC=/tmp/core-geth ./scripts/update-lists.sh --dry-run
```

Exit codes: `0` published or dry run clean, `1` refused or failed, `2`
did-not-run.

No linter or formatter is configured and no CI job runs one — match the existing
style by hand. `bash -n` parses the script and `shellcheck -S style` is worth
running, but nothing gates on either.

## Structure

```
scripts/update-lists.sh                 # seed, crawl, filter, cap, sign, publish
.github/workflows/update-dns-lists.yml  # runs it; builds devp2p, handles secrets, commits
all.json                                # working node set, unfiltered, cumulative
all.<network>.<domain>/nodes.json       # one published tree per network per domain
```

`all.*` directories are **generated output committed by the workflow**. Never
hand-edit a `nodes.json`.

## The numbers are load-bearing

- **Caps** (`CAP_CLASSIC=120`, `CAP_MORDOR=15`) come from the DNS zone
  budget, not from crawl yield. A Cloudflare free-plan zone holds 200 records and
  discovery does not get all of it — these domains also carry mail records, the
  apex site and service subdomains. Raising a cap eats that headroom.
- **Floors** (`MIN_NODES_CLASSIC=40`, `MIN_NODES_MORDOR=5`) are guards against a
  broken run, **not targets**. Mordor's 5 is deliberate — its ceiling is the
  network, not the crawl.
- **Shrink tolerance** (50% of the last *committed* tree) is the only guard
  against a crawl that lost its seed trees. It reads its baseline with
  `git show HEAD:<dir>/nodes.json`, so the commit step is load-bearing: with
  nothing committed there is no baseline and the check cannot fire.

Both checks refuse rather than publish. Refusing is always the correct
direction — a client cannot tell a broken crawl from a quiet network.

## Ask before

- **Pushing anything.** Public Ethereum Classic organization repository.
- **Committing anything**, documentation included.
- **Uncommenting the `schedule:` block.** It is off on purpose: until one
  supervised run has published and committed a tree, the shrink check has no
  baseline.
- **Changing a cap, floor or the shrink tolerance.**
- **Adding a domain, DNS provider or publisher.** `devp2p` automates Cloudflare
  and Route53 only; anything else is published from `to-txt` output.
- **Editing anything under `.github/workflows/`.** These run in the
  organization's CI with the organization's secrets.

## Never

- **Commit a signing key in any form, encrypted or not.** Its public half is
  compiled into every client as the `enrtree://<pubkey>@<domain>` prefix; losing
  the private half means rebuilding every release that shipped it. It lives only
  in the `DNS_SIGNING_KEY` secret.
- **Commit any credential**, DNS API token included.
- **Use `git add .` or `git add -A`.** Stage named paths — a run leaves
  untracked build output beside the trees it should commit.
- **Add, change, or recommend changing `LICENSE`.** That is the operator's call
  and a legal question before a technical one.
- **Publish a tree that failed a check**, or weaken a check so a tree passes.

## Response style

- Code and commands first; explain only what was asked about.
- Concise bullets over paragraphs; tables for comparisons.
- No pleasantries, and do not repeat the prompt back.
- Say what you verified and how.
