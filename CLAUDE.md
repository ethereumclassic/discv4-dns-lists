@AGENTS.md

# Claude Code notes

`AGENTS.md` above is the project context and is imported, not summarized. What
follows is Claude-specific and adds to it; where the two could be read as
disagreeing, `AGENTS.md` wins.

## Before acting

- **Read `README.md` before changing the pipeline.** It carries the measurements
  behind every cap, floor and design choice. A number changed without reading it
  is a number changed without knowing what it protects.
- **This repository is bootstrap infrastructure for a live network.** Treat
  publishing, pushing and enabling the schedule as one-way doors. `AGENTS.md`
  lists what needs confirmation; that list is not advisory.

## Model selection

Select by role, using the tier alias — an alias resolves to the newest model in
its tier, so it does not go stale the way a model name does.

| Alias | Use it for |
|---|---|
| `haiku` | typo fixes, mechanical edits, reading a file back |
| `sonnet` | the default: documentation, workflow edits, review |
| `opus` | changing the pipeline's guards, key handling, or DNS publishing logic |

Switch with `/model haiku`, `/model sonnet`, `/model opus`. Current prices,
context windows and the model behind each alias are documented at
<https://platform.claude.com/docs/en/about-claude/models/overview>.

## Machine-local context

Anything specific to one contributor's machine — local checkout paths, personal
tool locations, private working notes — belongs in `CLAUDE.local.md` at this
repository's root, never in this file or in `AGENTS.md`. Both of those are
committed and travel to every clone.

Confirm `CLAUDE.local.md` is actually ignored before writing one, by effect
rather than by reading the patterns:

```bash
git check-ignore --no-index -q -- CLAUDE.local.md && echo ignored || echo "NOT ignored"
git check-ignore --no-index -q -- README.md && echo "check is broken" || echo "check discriminates"
```

The second line is the calibration. A check that cannot report "not ignored" is
not checking anything, and its all-clear means nothing.

## Response style

- Code and commands first; explain only what was asked about.
- Concise bullets over paragraphs. Tables for comparisons.
- No pleasantries, and do not repeat the prompt back.
- State what you verified and how. "Tests pass" without naming what ran is not a
  result.
