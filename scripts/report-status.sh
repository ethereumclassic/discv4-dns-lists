#!/usr/bin/env bash
#
# Keep one status issue for the nightly run: rewrite it every run, and comment
# only when the state changes.
#
#   GITHUB_REPOSITORY=owner/repo GH_TOKEN=... \
#   ./scripts/report-status.sh <success|failure|cancelled> <run url> [run log]
#
# A failing run must not be silent, and a run that keeps failing must not open
# an issue a night. So there is exactly one issue, labelled STATUS_LABEL and
# opened by the workflow itself, and every run rewrites its title and body with
# the latest result. GitHub notifies nobody of an edit, so the run also comments
# on the first failure after a success and on the first success after a failure:
# subscribing to the issue is how to be told about exactly those two events.
#
# The issue is found by its label and its author, never its title: anyone can
# open an issue with a matching title, and only people with triage rights can
# apply a label. Only the run log's ERROR lines are copied into it, never the
# log itself, because the issue is public.
#
# Exit 0 reported, 1 could not report.

set -uo pipefail

[ $# -ge 2 ] || { echo "usage: $0 <success|failure|cancelled> <run url> [run log]" >&2; exit 1; }
[ -n "${GITHUB_REPOSITORY:-}" ] || { echo "report-status: GITHUB_REPOSITORY is unset" >&2; exit 1; }

python3 - "$@" <<'PYEOF'
import datetime, json, os, re, subprocess, sys

outcome, run_url = sys.argv[1], sys.argv[2]
log = sys.argv[3] if len(sys.argv) > 3 else ""
gh = os.environ.get("GH", "gh")
repo = os.environ["GITHUB_REPOSITORY"]
label = os.environ.get("STATUS_LABEL", "pipeline-status")
now = os.environ.get("NOW") or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
BOTS = {"app/github-actions", "github-actions", "github-actions[bot]"}

def gh_run(args, body=None):
    r = subprocess.run([gh, *args, "--repo", repo], input=body, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("report-status: gh %s failed: %s" % (" ".join(args[:2]), r.stderr.strip()))
    return r.stdout

# The latest failure's ERROR lines, bounded, and unable to close the code fence.
errors = []
if log and os.path.exists(log):
    for line in open(log, errors="replace"):
        if re.match(r"\s*ERROR:", line):
            errors.append(line.rstrip()[:240].replace("```", "'''"))
errors = errors[:20] or ["(no ERROR line in the run's output; see the run log)"]

gh_run(["label", "create", label, "--color", "5319e7", "--force",
        "--description", "The nightly run's status issue, maintained by the workflow"])
found = json.loads(gh_run(["issue", "list", "--label", label, "--state", "all", "--limit", "20",
                           "--json", "number,state,body,author"]) or "[]")
found = sorted((i for i in found if (i.get("author") or {}).get("login") in BOTS), key=lambda i: i["number"])
issue = found[0] if found else None

prev, prev_failure = {}, ""
if issue:
    m = re.search(r"<!-- status: (\{.*?\}) -->", issue.get("body") or "")
    if m:
        try:
            prev = json.loads(m.group(1))
        except ValueError:
            prev = {}
    f = re.search(r"<!-- latest-failure:start -->.*?<!-- latest-failure:end -->", issue.get("body") or "", re.S)
    prev_failure = f.group(0) if f else ""

was_failing = prev.get("state") == "failing"
if outcome == "success":
    st = {"state": "passing", "since": None, "failures": 0,
          "last_success": now, "last_failure": prev.get("last_failure")}
    comment = ("**Recovered** as of %s ([workflow run](%s)), after %d failed run%s."
               % (now, run_url, prev.get("failures", 1), "" if prev.get("failures", 1) == 1 else "s")
               if was_failing else None)
    failure_section = prev_failure
    title = "DNS lists: passing, last success %s" % now
else:
    n = prev.get("failures", 0) + 1 if was_failing else 1
    st = {"state": "failing", "since": prev.get("since") if was_failing else now, "failures": n,
          "last_success": prev.get("last_success"), "last_failure": now}
    block = "```\n%s\n```" % "\n".join(errors)
    comment = (None if was_failing else
               "**Failing** as of %s ([workflow run](%s)): the run %s.\n\n%s"
               % (now, run_url, "was cancelled" if outcome == "cancelled" else "did not complete", block))
    failure_section = ("<!-- latest-failure:start -->\n### Latest failure: %s\n\n%s\n<!-- latest-failure:end -->"
                       % (now, block))
    title = "DNS lists: FAILING since %s (%d run%s)" % (st["since"], n, "" if n == 1 else "s")

body = "\n".join([
    "<!-- status: %s -->" % json.dumps(st),
    "This issue is the status page for the nightly **Update DNS discovery lists** workflow. The",
    "workflow rewrites it on every scheduled run, and comments on it only when the state changes:",
    "on the first failure after a success, and on the first success after a failure. **Subscribe",
    "to this issue to be notified of exactly those.** Please do not close it.",
    "",
    "Owners: @ethereumclassic/core-developers",
    "",
    "| | |",
    "|---|---|",
    "| State | **%s** |" % ("passing" if st["state"] == "passing" else "FAILING"),
    "| Last run | %s, [workflow run](%s) |" % (now, run_url),
    "| Last success | %s |" % (st["last_success"] or "none recorded"),
    "| Last failure | %s |" % (st["last_failure"] or "none recorded"),
    "| Consecutive failures | %d |" % st["failures"],
    "",
    failure_section,
]).rstrip() + "\n"

if issue is None:
    print(gh_run(["issue", "create", "--title", title, "--label", label, "--body-file", "-"], body).strip())
else:
    num = str(issue["number"])
    if issue.get("state", "").upper() == "CLOSED":
        gh_run(["issue", "reopen", num])
    gh_run(["issue", "edit", num, "--title", title, "--body-file", "-"], body)
    if comment:
        gh_run(["issue", "comment", num, "--body-file", "-"], comment)
    print("status issue #%s: %s%s" % (num, st["state"], ", commented" if comment else ""))
PYEOF
