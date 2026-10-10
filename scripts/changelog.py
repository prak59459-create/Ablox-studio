#!/usr/bin/env python3
"""Keeps changelog.json — every version's notes — in step with update.json.

update.json says only what the newest version changed. changelog.json, beside
it, keeps every release, newest first; the app shows it in Settings → Updates
→ Update history (`UpdateHistory` in AbloxCore).

    python3 scripts/changelog.py            add update.json's release to changelog.json
    python3 scripts/changelog.py --check    fail if changelog.json's newest release is not update.json's
    python3 scripts/changelog.py --from-git rebuild changelog.json from every update.json in git history

Run it after writing update.json's "notes" (scripts/release.sh says so);
scripts/check-release.sh runs --check.
"""
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UPDATE = os.path.join(ROOT, "update.json")
CHANGELOG = os.path.join(ROOT, "changelog.json")


def norm(version):
    parts = [int(p) for p in str(version).split(".")]
    return tuple(parts + [0] * (4 - len(parts)))


def release_of(update):
    return {
        "version": update["version"],
        "build": int(update["build"]),
        "date": update["date"],
        "notes": {k: list(v) for k, v in update.get("notes", {}).items()},
    }


def ordered(releases):
    seen = set()
    unique = []
    for r in releases:
        key = (norm(r["version"]), r["build"])
        if key in seen:
            continue
        seen.add(key)
        unique.append(r)
    return sorted(unique, key=lambda r: (norm(r["version"]), r["build"]), reverse=True)


def write(app, releases):
    with open(CHANGELOG, "w") as f:
        json.dump({"app": app, "releases": ordered(releases)}, f, ensure_ascii=False, indent=2)
        f.write("\n")


def load_changelog(app):
    if not os.path.exists(CHANGELOG):
        return {"app": app, "releases": []}
    with open(CHANGELOG) as f:
        return json.load(f)


def main():
    update = json.load(open(UPDATE))
    app = update["app"]
    mode = sys.argv[1] if len(sys.argv) > 1 else ""

    if mode == "--check":
        log = load_changelog(app)
        problems = []
        if log.get("app") != app:
            problems.append(f"changelog.json is for {log.get('app')!r}, update.json for {app!r}")
        releases = log.get("releases") or []
        if not releases:
            problems.append("changelog.json has no releases")
        elif releases[0] != release_of(update):
            top = releases[0]
            problems.append(f"changelog.json's newest release is {top.get('version')} ({top.get('build')}), "
                            f"not update.json's {update['version']} ({update['build']}) with the same date and notes")
        if releases != ordered(releases):
            problems.append("changelog.json is not newest first, or lists a release twice")
        if problems:
            print("✗ changelog.json is behind update.json — run python3 scripts/changelog.py:")
            for p in problems:
                print("   ", p)
            sys.exit(1)
        print(f"✓ changelog.json: {len(releases)} releases, newest {update['version']} ({update['build']})")
        return

    if mode == "--from-git":
        commits = subprocess.run(["git", "-C", ROOT, "log", "--format=%H", "--", "update.json"],
                                 capture_output=True, text=True, check=True).stdout.split()
        releases = []
        for commit in commits:
            shown = subprocess.run(["git", "-C", ROOT, "show", f"{commit}:update.json"], capture_output=True, text=True)
            if shown.returncode != 0:
                continue
            try:
                old = json.loads(shown.stdout)
                releases.append(release_of(old))
            except (ValueError, KeyError):
                continue
        # The working copy first, so it wins over a committed copy of the same release.
        write(app, [release_of(update)] + releases)
        print(f"✓ changelog.json rebuilt from git: {len(ordered([release_of(update)] + releases))} releases")
        return

    if mode:
        sys.exit(__doc__)

    log = load_changelog(app)
    mine = release_of(update)
    others = [r for r in log.get("releases", [])
              if (norm(r["version"]), r["build"]) != (norm(mine["version"]), mine["build"])]
    write(app, [mine] + others)
    print(f"✓ changelog.json: {update['version']} ({update['build']}) added")


if __name__ == "__main__":
    main()
