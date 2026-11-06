#!/usr/bin/env python3
"""
Builds the RaDown source: one list of Rashid's own apps, made from the latest
release of each of his public repositories, in the format RaDown reads.

Each release's .ipa is opened only far enough to read its Info.plist and its
largest icon, so the entry carries the app's real name, bundle identifier and
version rather than the repository's.

A repository whose release has not changed since the last run is copied over
from the existing source instead of being downloaded again.

Run by .github/workflows/source.yml; GH_TOKEN must be set.
"""

import io
import json
import os
import plistlib
import re
import subprocess
import sys
import zipfile
from pathlib import Path

OWNER = "polatmsmakm-ctrl"
ROOT = Path(__file__).resolve().parent.parent
SOURCE_PATH = ROOT / "source.json"
ICON_DIR = ROOT / "icons"

SOURCE_ID = "rashid.radown.source"
SOURCE_NAME = "تطبيقات راشد"
SOURCE_SUBTITLE = "Rashid's apps"
WEBSITE = f"https://github.com/{OWNER}"
TINT = "848ef9"

# Repositories that are not apps of his own, or are forks of other people's.
SKIP = {"RaDown", "radown", "Play-", "nazzel-desktop", "OneTapRecorder", "FiveStar"}

MAX_IPA_BYTES = 300 * 1024 * 1024


def gh(path, params=""):
    """One GitHub REST call through the gh CLI, which already holds the token."""
    url = f"{path}{params}"
    out = subprocess.run(
        ["gh", "api", "-H", "Accept: application/vnd.github+json", url],
        capture_output=True,
        text=True,
    )
    if out.returncode != 0:
        return None
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError:
        return None


def public_repos():
    repos, page = [], 1
    while page <= 10:
        batch = gh(f"users/{OWNER}/repos", f"?per_page=100&page={page}&type=owner")
        if not batch:
            break
        repos.extend(r for r in batch if not r.get("private"))
        if len(batch) < 100:
            break
        page += 1
    return repos


def latest_ipa_release(repo_name):
    releases = gh(f"repos/{OWNER}/{repo_name}/releases", "?per_page=20")
    if not releases:
        return None

    for release in releases:
        if release.get("draft"):
            continue
        for asset in release.get("assets", []):
            name = asset.get("name", "")
            if name.lower().endswith((".ipa", ".tipa")) and asset.get("size", 0) <= MAX_IPA_BYTES:
                return release, asset
    return None


def download(url, dest):
    result = subprocess.run(
        ["curl", "-fsSL", "--retry", "2", "-o", str(dest), url],
        capture_output=True,
    )
    return result.returncode == 0


def read_ipa(path, repo_name):
    """The app's own details, read out of the package."""
    try:
        with zipfile.ZipFile(path) as z:
            names = z.namelist()

            plist_name = next(
                (n for n in names if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)),
                None,
            )
            if not plist_name:
                return None

            info = plistlib.loads(z.read(plist_name))
            app_dir = plist_name.rsplit("/", 1)[0]

            identifier = info.get("CFBundleIdentifier")
            if not identifier:
                return None

            icon_rel = extract_icon(z, names, app_dir, info, repo_name)

            return {
                "identifier": identifier,
                "name": info.get("CFBundleDisplayName") or info.get("CFBundleName") or repo_name,
                "version": str(info.get("CFBundleShortVersionString") or "1.0"),
                "minOS": str(info.get("MinimumOSVersion") or ""),
                "icon": icon_rel,
            }
    except (zipfile.BadZipFile, plistlib.InvalidFileException, KeyError):
        return None


def extract_icon(z, names, app_dir, info, repo_name):
    """The largest icon in the bundle, saved next to the source."""
    candidates = []

    icons = info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {})
    for base in icons.get("CFBundleIconFiles", []) or []:
        candidates += [n for n in names if n.startswith(f"{app_dir}/{base}") and n.endswith(".png")]

    if not candidates:
        candidates = [
            n for n in names
            if n.startswith(f"{app_dir}/")
            and n.endswith(".png")
            and re.search(r"(?i)appicon|icon", n.rsplit("/", 1)[-1])
            and "/" not in n[len(app_dir) + 1:]
        ]

    if not candidates:
        return None

    def size_of(n):
        """Pixels, so AppIcon60x60@3x beats AppIcon76x76."""
        match = re.search(r"(\d+)x(\d+)", n)
        points = int(match.group(1)) if match else 0
        scale = re.search(r"@(\d)x", n)
        return points * (int(scale.group(1)) if scale else 1)

    best = max(candidates, key=lambda n: (size_of(n), z.getinfo(n).file_size))

    ICON_DIR.mkdir(exist_ok=True)
    out = ICON_DIR / f"{repo_name}.png"
    out.write_bytes(z.read(best))
    return f"icons/{repo_name}.png"


def existing_entries():
    if not SOURCE_PATH.exists():
        return {}
    try:
        data = json.loads(SOURCE_PATH.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}
    return {
        app["_repo"]: app
        for app in data.get("apps", [])
        if isinstance(app, dict) and app.get("_repo")
    }


def main():
    previous = existing_entries()
    apps = []

    for repo in sorted(public_repos(), key=lambda r: r["name"].lower()):
        name = repo["name"]
        if name in SKIP:
            continue

        found = latest_ipa_release(name)
        if not found:
            continue

        release, asset = found
        tag = release.get("tag_name", "")
        updated = asset.get("updated_at", "")
        stamp = f"{tag}|{updated}"

        old = previous.get(name)
        if old and old.get("_stamp") == stamp:
            apps.append(old)
            print(f"= {name} ({tag}) unchanged")
            continue

        tmp = Path(f"/tmp/{name}.ipa")
        if not download(asset["browser_download_url"], tmp):
            if old:
                apps.append(old)
            print(f"! {name}: could not download", file=sys.stderr)
            continue

        details = read_ipa(tmp, name)
        tmp.unlink(missing_ok=True)

        if not details:
            if old:
                apps.append(old)
            print(f"! {name}: not a readable app package", file=sys.stderr)
            continue

        raw_icon = (
            f"https://raw.githubusercontent.com/{OWNER}/RaDown/main/{details['icon']}"
            if details["icon"]
            else None
        )

        entry = {
            "_repo": name,
            "_stamp": stamp,
            "name": details["name"],
            "bundleIdentifier": details["identifier"],
            "developerName": "Rashid",
            "subtitle": (repo.get("description") or "")[:80] or None,
            "localizedDescription": repo.get("description") or details["name"],
            "iconURL": raw_icon,
            "tintColor": TINT,
            "version": details["version"],
            "versionDate": asset.get("updated_at"),
            "size": asset.get("size", 0),
            "downloadURL": asset["browser_download_url"],
            "versions": [
                {
                    "version": details["version"],
                    "date": asset.get("updated_at"),
                    "size": asset.get("size", 0),
                    "downloadURL": asset["browser_download_url"],
                    "localizedDescription": (release.get("body") or "")[:400] or None,
                    "minOSVersion": details["minOS"] or None,
                }
            ],
        }

        apps.append({k: v for k, v in entry.items() if v is not None})
        print(f"+ {name}: {details['name']} {details['version']}")

    if not apps:
        print("no apps found; leaving the existing source alone", file=sys.stderr)
        return 1

    source = {
        "name": SOURCE_NAME,
        "identifier": SOURCE_ID,
        "subtitle": SOURCE_SUBTITLE,
        "description": "كل تطبيقات راشد، تتحدّث تلقائيًا مع كل إصدار جديد.",
        "website": WEBSITE,
        "tintColor": TINT,
        "iconURL": apps[0].get("iconURL"),
        "apps": apps,
        "news": [],
    }

    SOURCE_PATH.write_text(
        json.dumps(source, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"\nwrote {len(apps)} apps to {SOURCE_PATH.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
