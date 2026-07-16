#!/usr/bin/env python3
"""
Collects DriveWise repo analytics and appends them to stats/history.json
(and a flattened stats/history.csv) so history survives past GitHub's
14-day traffic retention window.

Run manually:
    GITHUB_TOKEN=<automatic-or-any-token> TRAFFIC_TOKEN=<fine-grained PAT, Administration:Read> python3 scripts/collect_stats.py

Normally this runs on a daily schedule via .github/workflows/repo-stats.yml.
Two tokens are used, for least-privilege reasons:
  - GITHUB_TOKEN   - the automatic Actions token. Used for public repo/release
                      reads and for committing stats/ back to the repo.
  - TRAFFIC_TOKEN  - a fine-grained personal access token stored as the repo
                      secret TRAFFIC_PAT, with "Administration: Read-only" on
                      this repo. That permission is required for the four
                      /traffic/* endpoints - the automatic GITHUB_TOKEN is not
                      allowed to call them, no matter what `permissions:` is
                      set in the workflow.
"""
import csv
import datetime
import json
import os
import urllib.error
import urllib.request

REPO = "aadesh0706/DriveWise"
API = "https://api.github.com"
TOKEN = os.environ.get("GITHUB_TOKEN", "")
TRAFFIC_TOKEN = os.environ.get("TRAFFIC_TOKEN") or TOKEN


def gh_get(path, token=None):
    req = urllib.request.Request(
        f"{API}{path}",
        headers={
            "Authorization": f"Bearer {token or TOKEN}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(req) as r:
        return json.load(r)


def load_history(path):
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    return {}


def save_history(path, data):
    with open(path, "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)


def main():
    os.makedirs("stats", exist_ok=True)
    history = load_history("stats/history.json")
    today = datetime.date.today().isoformat()
    history.setdefault(today, {})

    # ---- Public repo-level stats (no special access needed) ----
    repo = gh_get(f"/repos/{REPO}")
    history[today]["stars"] = repo.get("stargazers_count", 0)
    history[today]["forks"] = repo.get("forks_count", 0)
    history[today]["watchers"] = repo.get("subscribers_count", repo.get("watchers_count", 0))
    history[today]["open_issues"] = repo.get("open_issues_count", 0)

    # ---- Release download counts (public) ----
    releases = gh_get(f"/repos/{REPO}/releases")
    total_downloads = 0
    for rel in releases:
        for asset in rel.get("assets", []):
            total_downloads += asset.get("download_count", 0)
    history[today]["release_downloads_total"] = total_downloads

    # ---- Traffic: views / clones ----
    # Requires "Administration: Read-only" on a fine-grained PAT (TRAFFIC_TOKEN).
    # The automatic GITHUB_TOKEN cannot access these endpoints at all.
    try:
        views = gh_get(f"/repos/{REPO}/traffic/views", token=TRAFFIC_TOKEN)
        for day in views.get("views", []):
            d = day["timestamp"][:10]
            history.setdefault(d, {})
            history[d]["views"] = day["count"]
            history[d]["unique_visitors"] = day["uniques"]
    except urllib.error.HTTPError as e:
        print(f"Could not fetch traffic/views ({e.code}) - set the TRAFFIC_PAT secret (Administration: Read-only).")

    try:
        clones = gh_get(f"/repos/{REPO}/traffic/clones", token=TRAFFIC_TOKEN)
        for day in clones.get("clones", []):
            d = day["timestamp"][:10]
            history.setdefault(d, {})
            history[d]["clones"] = day["count"]
            history[d]["unique_cloners"] = day["uniques"]
    except urllib.error.HTTPError as e:
        print(f"Could not fetch traffic/clones ({e.code}) - set the TRAFFIC_PAT secret (Administration: Read-only).")

    # ---- Where visitors come from / what they look at (same permission) ----
    for label, path in [("popular_paths", "paths"), ("popular_referrers", "referrers")]:
        try:
            data = gh_get(f"/repos/{REPO}/traffic/popular/{path}", token=TRAFFIC_TOKEN)
            with open(f"stats/{label}.json", "w") as f:
                json.dump(data, f, indent=2)
        except urllib.error.HTTPError as e:
            print(f"Could not fetch traffic/popular/{path} ({e.code}).")

    save_history("stats/history.json", history)

    # ---- Flat CSV for easy spreadsheet / chart import ----
    fields = [
        "date", "views", "unique_visitors", "clones", "unique_cloners",
        "stars", "forks", "watchers", "open_issues", "release_downloads_total",
    ]
    with open("stats/history.csv", "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(fields)
        for d in sorted(history.keys()):
            row = history[d]
            writer.writerow([d] + [row.get(k, "") for k in fields[1:]])

    print(f"Stats updated for {today}: {history[today]}")


if __name__ == "__main__":
    main()
