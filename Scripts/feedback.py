#!/usr/bin/env python3
"""Read StitchPeek feedback — for agents working the queue.

    python3 Scripts/feedback.py list            open feedback, newest first
    python3 Scripts/feedback.py list --all      including closed
    python3 Scripts/feedback.py show <number>   the report, plus its screenshot and any
                                                attached design downloaded locally

Feedback is filed from inside the app (Help → Send Feedback) as issues in a private
repository. `show` downloads attachments to /tmp/stitchpeek-feedback/<number>/ and prints
their paths: Read the screenshot to see what the person saw, including the numbered markers
they placed on it. Needs the `gh` CLI, authenticated with access to that repository.
"""
import json
import os
import re
import subprocess
import sys
import urllib.parse

REPO = "bobbymarko/StitchPeek-feedback"
OUT = "/tmp/stitchpeek-feedback"


def gh(*args, binary=False):
    result = subprocess.run(["gh", *args], capture_output=True, text=not binary)
    if result.returncode != 0:
        err = result.stderr if not binary else result.stderr.decode(errors="replace")
        sys.exit(f"gh {' '.join(args[:3])}… failed: {err.strip()}")
    return result.stdout


def list_feedback(include_closed):
    state = "all" if include_closed else "open"
    issues = json.loads(gh(
        "issue", "list", "-R", REPO, "--label", "feedback", "--state", state,
        "--limit", "200", "--json", "number,title,labels,createdAt,state",
    ))
    if not issues:
        print("No feedback." if include_closed else "No open feedback.")
        return
    for issue in issues:
        kinds = [label["name"] for label in issue["labels"] if label["name"] != "feedback"]
        print(f"#{issue['number']:<4} {issue['state'].lower():<6} {issue['createdAt'][:10]}  "
              f"[{', '.join(kinds) or '-'}]  {issue['title']}")


def show(number):
    issue = json.loads(gh(
        "issue", "view", str(number), "-R", REPO,
        "--json", "number,title,body,state,labels,comments,url",
    ))
    print(f"#{issue['number']} [{issue['state'].lower()}] {issue['title']}")
    print(issue["url"])
    print()
    print(issue["body"])
    for comment in issue.get("comments", []):
        print(f"\n--- {comment['author']['login']} ({comment['createdAt'][:10]}) ---\n{comment['body']}")

    # Attachments are committed into the feedback repo and linked as blob URLs.
    pattern = rf"https://github\.com/{re.escape(REPO)}/blob/[^/]+/([^)\s?]+)"
    paths = sorted(set(re.findall(pattern, issue["body"])))
    if not paths:
        return
    destination = os.path.join(OUT, str(number))
    os.makedirs(destination, exist_ok=True)
    print("\nAttachments:")
    for path in paths:
        data = gh("api", f"repos/{REPO}/contents/{path}", "-H", "Accept: application/vnd.github.raw", binary=True)
        local = os.path.join(destination, os.path.basename(urllib.parse.unquote(path)))
        with open(local, "wb") as f:
            f.write(data)
        print(f"  {local}")


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("list", "show"):
        sys.exit(__doc__)
    if sys.argv[1] == "list":
        list_feedback("--all" in sys.argv)
    else:
        if len(sys.argv) < 3 or not sys.argv[2].lstrip("#").isdigit():
            sys.exit("usage: feedback.py show <number>")
        show(int(sys.argv[2].lstrip("#")))


if __name__ == "__main__":
    main()
