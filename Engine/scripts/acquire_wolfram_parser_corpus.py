#!/usr/bin/env python3
"""
Acquire a parser-focused Wolfram corpus for Tungsten.

This tool builds a large local-only parser corpus under C:\\TestData by combining:

1. sparse snapshots of public GitHub repositories, preserving only Wolfram notebook/package-ish
   files plus root license/readme metadata; and
2. bulk downloads of Notebook Archive notebooks using the archive's own published indexes plus
   the same Wolfram Cloud download-resolution API used by the website.

The intended use is local parser-corpus mining. The fetched third-party materials are not meant to
be bundled into Tungsten or redistributed from this workspace.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from collections import Counter
from pathlib import Path
from typing import Any


CORPUS_EXTENSIONS = {
    ".nb",
    ".nbp",
    ".m",
    ".mt",
    ".paclet",
    ".wl",
    ".wls",
    ".wlt",
}

ROOT_METADATA_PATTERNS = (
    "/LICENSE*",
    "/license*",
    "/COPYING*",
    "/copying*",
    "/NOTICE*",
    "/notice*",
    "/README*",
    "/readme*",
)

CURATED_REPOSITORIES: list[dict[str, Any]] = [
    {
        "id": "wolframresearch-chatbook",
        "repo": "WolframResearch/Chatbook",
        "why": "Large actively maintained Wolfram Language paclet and notebook codebase.",
    },
    {
        "id": "wolframresearch-agenttools",
        "repo": "WolframResearch/AgentTools",
        "why": "Modern Wolfram Language package surface with notebook-facing tooling.",
    },
    {
        "id": "wolframresearch-quantumframework",
        "repo": "WolframResearch/QuantumFramework",
        "why": "Substantial real-world Wolfram Language framework with many packages and notebooks.",
    },
    {
        "id": "wolframresearch-arrival-movie-live-coding",
        "repo": "WolframResearch/Arrival-Movie-Live-Coding",
        "why": "Notebook-heavy example repository with rich real-world notebook structure.",
    },
    {
        "id": "wolframresearch-lspserver",
        "repo": "WolframResearch/LSPServer",
        "why": "Parser-adjacent Wolfram Language codebase with packages and editor-facing artifacts.",
    },
    {
        "id": "wolframresearch-femaddons",
        "repo": "WolframResearch/FEMAddOns",
        "why": "Package-oriented Mathematica repository with substantial source surface.",
    },
    {
        "id": "wolframresearch-wolframlanguageforjupyter",
        "repo": "WolframResearch/WolframLanguageForJupyter",
        "why": "Small but high-signal repo with notebooks, packages, and integration examples.",
    },
    {
        "id": "wolframresearch-codeparser",
        "repo": "WolframResearch/codeparser",
        "why": "Official parser project with syntax-heavy Wolfram Language source and fixtures.",
    },
    {
        "id": "wolframresearch-codeinspector",
        "repo": "WolframResearch/codeinspector",
        "why": "Official code-analysis project with many tricky code samples and packages.",
    },
    {
        "id": "wolframresearch-codeformatter",
        "repo": "WolframResearch/codeformatter",
        "why": "Official formatter project with parser-relevant Wolfram source and examples.",
    },
    {
        "id": "wolframresearch-csstools",
        "repo": "WolframResearch/CSSTools",
        "why": "Package-rich Mathematica repository with varied practical source inputs.",
    },
    {
        "id": "wolframresearch-imagemetadatatools",
        "repo": "WolframResearch/ImageMetadataTools",
        "why": "Compact modern Wolfram Language paclet source.",
    },
    {
        "id": "wolframresearch-pacletcicd",
        "repo": "WolframResearch/PacletCICD",
        "why": "Modern paclet infrastructure repo with package-oriented real code.",
    },
    {
        "id": "wolframresearch-pacletcicd-example-sample",
        "repo": "WolframResearch/PacletCICD-Examples-Sample",
        "why": "Representative sample paclet structure with parser-friendly source files.",
    },
    {
        "id": "wolframresearch-bioformatslink",
        "repo": "WolframResearch/BioFormatsLink",
        "why": "Large practical Mathematica link repo with many package files.",
    },
    {
        "id": "wolframresearch-draw",
        "repo": "WolframResearch/draw",
        "why": "Compact Wolfram Language source corpus with notebooks and packages.",
    },
    {
        "id": "wolframresearch-datacurationtraining",
        "repo": "WolframResearch/Data-Curation-Training",
        "why": "Training notebooks and Wolfram Language materials with realistic notebook structure.",
    },
    {
        "id": "wolframresearch-semantic-math",
        "repo": "WolframResearch/semantic-math",
        "why": "Package-heavy Mathematica repo with nontrivial source structure.",
    },
    {
        "id": "wolframresearch-distmesh",
        "repo": "WolframResearch/DistMesh",
        "why": "Small but canonical Mathematica package corpus.",
    },
    {
        "id": "mathics-core",
        "repo": "Mathics3/mathics-core",
        "why": "Large maintained WL-like implementation with useful notebooks and package-like source.",
    },
    {
        "id": "mathics3-scanner",
        "repo": "Mathics3/Mathics3-scanner",
        "why": "Tokenizer/parser-adjacent sources that may contribute syntax samples.",
    },
    {
        "id": "woxi",
        "repo": "ad-si/Woxi",
        "why": "Subset WL interpreter with scripts and fixtures useful as parser corpus.",
    },
    {
        "id": "foxysheep",
        "repo": "rljacobson/FoxySheep",
        "why": "Alternative parser implementation with useful syntax examples.",
    },
    {
        "id": "matex",
        "repo": "szhorvat/MaTeX",
        "why": "Popular real-world Mathematica package with practical source files.",
    },
    {
        "id": "igraphm",
        "repo": "szhorvat/IGraphM",
        "why": "Large community Mathematica package surface.",
    },
    {
        "id": "ltemplate",
        "repo": "szhorvat/LTemplate",
        "why": "Community Wolfram package source with varied notebook/package content.",
    },
    {
        "id": "setreplace",
        "repo": "maxitg/SetReplace",
        "why": "Nontrivial Mathematica package and notebook corpus from the community ecosystem.",
    },
    {
        "id": "wljs-notebook",
        "repo": "WLJSTeam/wljs-notebook",
        "why": "Large notebook-centric ecosystem repo likely to contain many parser inputs.",
    },
]

DEFAULT_DISCOVERY_QUERIES = [
    "topic:wolfram-language fork:false archived:false",
    "topic:mathematica fork:false archived:false",
    "topic:wolfram-mathematica fork:false archived:false",
]

DEFAULT_DISCOVERY_ORGS = [
    "WolframResearch",
    "Mathics3",
]

NOTEBOOK_ARCHIVE_INDEXES = {
    "non_historical": "https://www.notebookarchive.org/inc/concatenated/all-non-historical-results.json",
    "historical": "https://www.notebookarchive.org/inc/concatenated/all-historical-results.json",
}


def utc_now_iso() -> str:
    return dt.datetime.now(dt.UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def run(
    cmd: list[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
) -> str:
    completed = subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=True,
    )
    return completed.stdout.strip()


def fetch_json(url: str, *, headers: dict[str, str] | None = None) -> Any:
    request = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(request, timeout=120) as response:
        return json.loads(response.read().decode("utf-8"))


def download_bytes(url: str, *, headers: dict[str, str] | None = None) -> bytes:
    request = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(request, timeout=300) as response:
        return response.read()


def normalized_extension(path: Path) -> str:
    return path.suffix.lower() if path.suffix else "[none]"


def make_repo_id(full_name: str) -> str:
    return full_name.lower().replace("/", "-").replace("_", "-")


def corpus_sparse_patterns() -> list[str]:
    patterns = list(ROOT_METADATA_PATTERNS)
    for ext in sorted(CORPUS_EXTENSIONS):
        patterns.append(f"/*{ext}")
        patterns.append(f"/**/*{ext}")
    return patterns


def github_headers(token: str | None) -> dict[str, str]:
    headers = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "Tungsten-Wolfram-Parser-Corpus",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def github_get_json(path_or_url: str, token: str | None) -> Any:
    if path_or_url.startswith("https://"):
        url = path_or_url
    else:
        url = f"https://api.github.com{path_or_url}"
    return fetch_json(url, headers=github_headers(token))


def github_search_repositories(query: str, *, token: str | None, limit: int) -> list[dict[str, Any]]:
    repos: list[dict[str, Any]] = []
    page = 1
    per_page = 100
    while len(repos) < limit:
        url = (
            "https://api.github.com/search/repositories?"
            + urllib.parse.urlencode(
                {
                    "q": query,
                    "sort": "stars",
                    "order": "desc",
                    "per_page": per_page,
                    "page": page,
                }
            )
        )
        payload = github_get_json(url, token)
        items = payload.get("items", [])
        if not items:
            break
        repos.extend(items)
        page += 1
        if page > 10:
            break
    return repos[:limit]


def github_list_org_repositories(org: str, *, token: str | None, limit: int) -> list[dict[str, Any]]:
    repos: list[dict[str, Any]] = []
    page = 1
    per_page = 100
    while len(repos) < limit:
        url = (
            f"https://api.github.com/orgs/{urllib.parse.quote(org)}/repos?"
            + urllib.parse.urlencode(
                {
                    "type": "public",
                    "sort": "updated",
                    "per_page": per_page,
                    "page": page,
                }
            )
        )
        payload = github_get_json(url, token)
        if not isinstance(payload, list) or not payload:
            break
        repos.extend(payload)
        page += 1
        if page > 20:
            break
    return repos[:limit]


def fetch_repository_metadata(full_name: str, *, token: str | None) -> dict[str, Any] | None:
    try:
        return github_get_json(f"/repos/{full_name}", token)
    except urllib.error.HTTPError:
        return None


def prepare_repository_candidates(
    *,
    token: str | None,
    max_discovered_repositories: int,
    max_discovered_repo_size_kb: int,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    included: list[dict[str, Any]] = []
    excluded: list[dict[str, Any]] = []
    seen: set[str] = set()

    for repo in CURATED_REPOSITORIES:
        full_name = repo["repo"]
        metadata = fetch_repository_metadata(full_name, token=token)
        default_branch = metadata.get("default_branch") if metadata else None
        clone_url = metadata.get("clone_url") if metadata else f"https://github.com/{full_name}.git"
        license_name = None
        if metadata and metadata.get("license"):
            license_name = metadata["license"].get("spdx_id") or metadata["license"].get("name")
        entry = {
            "id": repo["id"],
            "repo": full_name,
            "clone_url": clone_url,
            "default_branch": default_branch or "master",
            "discovery_kind": "curated",
            "discovery_reason": repo["why"],
            "description": metadata.get("description") if metadata else None,
            "license": license_name,
            "pushed_at": metadata.get("pushed_at") if metadata else None,
        }
        included.append(entry)
        seen.add(full_name.lower())

    discovered_total = 0

    for query in DEFAULT_DISCOVERY_QUERIES:
        if discovered_total >= max_discovered_repositories:
            break
        remaining = max_discovered_repositories - discovered_total
        for item in github_search_repositories(query, token=token, limit=remaining):
            full_name = item["full_name"]
            if full_name.lower() in seen:
                continue
            if item.get("fork"):
                excluded.append({"repo": full_name, "reason": "GitHub discovery returned a fork; skipping."})
                continue
            if item.get("archived"):
                excluded.append({"repo": full_name, "reason": "Repository is archived; skipping discovery candidate."})
                continue
            size_kb = int(item.get("size") or 0)
            if size_kb > max_discovered_repo_size_kb:
                excluded.append(
                    {
                        "repo": full_name,
                        "reason": (
                            f"Discovered repository is larger than the configured limit "
                            f"({size_kb} KB > {max_discovered_repo_size_kb} KB)."
                        ),
                    }
                )
                continue
            license_name = None
            if item.get("license"):
                license_name = item["license"].get("spdx_id") or item["license"].get("name")
            included.append(
                {
                    "id": make_repo_id(full_name),
                    "repo": full_name,
                    "clone_url": item.get("clone_url") or f"https://github.com/{full_name}.git",
                    "default_branch": item.get("default_branch") or "master",
                    "discovery_kind": "github-search",
                    "discovery_reason": query,
                    "description": item.get("description"),
                    "license": license_name,
                    "pushed_at": item.get("pushed_at"),
                }
            )
            seen.add(full_name.lower())
            discovered_total += 1
            if discovered_total >= max_discovered_repositories:
                break

    for org in DEFAULT_DISCOVERY_ORGS:
        if discovered_total >= max_discovered_repositories:
            break
        remaining = max_discovered_repositories - discovered_total
        for item in github_list_org_repositories(org, token=token, limit=remaining):
            full_name = item["full_name"]
            if full_name.lower() in seen:
                continue
            if item.get("fork"):
                continue
            if item.get("archived"):
                excluded.append({"repo": full_name, "reason": "Archived repository from org discovery; skipping."})
                continue
            size_kb = int(item.get("size") or 0)
            if size_kb > max_discovered_repo_size_kb:
                excluded.append(
                    {
                        "repo": full_name,
                        "reason": (
                            f"Organization repository is larger than the configured discovery limit "
                            f"({size_kb} KB > {max_discovered_repo_size_kb} KB)."
                        ),
                    }
                )
                continue
            license_name = None
            if item.get("license"):
                license_name = item["license"].get("spdx_id") or item["license"].get("name")
            included.append(
                {
                    "id": make_repo_id(full_name),
                    "repo": full_name,
                    "clone_url": item.get("clone_url") or f"https://github.com/{full_name}.git",
                    "default_branch": item.get("default_branch") or "master",
                    "discovery_kind": "github-org",
                    "discovery_reason": org,
                    "description": item.get("description"),
                    "license": license_name,
                    "pushed_at": item.get("pushed_at"),
                }
            )
            seen.add(full_name.lower())
            discovered_total += 1
            if discovered_total >= max_discovered_repositories:
                break

    return included, excluded


def remove_git_dir(repo_root: Path) -> None:
    git_dir = repo_root / ".git"
    if git_dir.exists():
        def onexc(func: Any, path: str, excinfo: Any) -> None:
            os.chmod(path, stat.S_IWRITE)
            func(path)

        shutil.rmtree(git_dir, onexc=onexc)


def iter_snapshot_files(repo_root: Path) -> list[Path]:
    return [path for path in repo_root.rglob("*") if path.is_file() and ".git" not in path.parts]


def extract_paclets(repo_root: Path) -> list[dict[str, Any]]:
    extracted: list[dict[str, Any]] = []
    for paclet_path in repo_root.rglob("*.paclet"):
        relative = paclet_path.relative_to(repo_root)
        extract_root = repo_root / "_paclet_extracted" / relative.with_suffix("")
        extract_root.mkdir(parents=True, exist_ok=True)
        extracted_file_count = 0
        try:
            with zipfile.ZipFile(paclet_path) as zf:
                for member in zf.infolist():
                    if member.is_dir():
                        continue
                    member_path = Path(member.filename)
                    if member_path.suffix.lower() not in CORPUS_EXTENSIONS and len(member_path.parts) != 1:
                        continue
                    destination = extract_root / member.filename
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    with zf.open(member) as src, destination.open("wb") as dst:
                        shutil.copyfileobj(src, dst)
                    extracted_file_count += 1
            extracted.append(
                {
                    "paclet": str(relative).replace("\\", "/"),
                    "extractedRoot": str(extract_root.relative_to(repo_root)).replace("\\", "/"),
                    "fileCount": extracted_file_count,
                    "status": "extracted",
                }
            )
        except zipfile.BadZipFile:
            extracted.append(
                {
                    "paclet": str(relative).replace("\\", "/"),
                    "status": "skipped-invalid-zip",
                }
            )
    return extracted


def apply_file_size_cap(repo_root: Path, *, max_file_bytes: int) -> list[dict[str, Any]]:
    removed: list[dict[str, Any]] = []
    for path in repo_root.rglob("*"):
        if not path.is_file():
            continue
        if path.suffix.lower() not in CORPUS_EXTENSIONS:
            continue
        size = path.stat().st_size
        if size <= max_file_bytes:
            continue
        removed.append(
            {
                "path": str(path.relative_to(repo_root)).replace("\\", "/"),
                "bytes": size,
                "reason": f"exceeds max file size of {max_file_bytes} bytes",
            }
        )
        path.unlink()
    return removed


def repository_histograms(files: list[Path], root: Path) -> tuple[dict[str, int], dict[str, int], int, int]:
    all_counter: Counter[str] = Counter()
    matched_counter: Counter[str] = Counter()
    total_bytes = 0
    matched_bytes = 0
    for path in files:
        ext = normalized_extension(path)
        size = path.stat().st_size
        all_counter[ext] += 1
        total_bytes += size
        if path.suffix.lower() in CORPUS_EXTENSIONS:
            matched_counter[ext] += 1
            matched_bytes += size
    return dict(sorted(all_counter.items())), dict(sorted(matched_counter.items())), total_bytes, matched_bytes


def materialize_repository(
    entry: dict[str, Any],
    *,
    out_root: Path,
    force: bool,
    fetch_lfs_content: bool,
    extract_paclets_flag: bool,
    max_file_bytes: int,
) -> dict[str, Any]:
    destination = out_root / entry["id"]
    if destination.exists():
        if not force:
            snapshot_path = destination / ".snapshot.json"
            if snapshot_path.exists():
                return json.loads(snapshot_path.read_text(encoding="utf-8"))
            return {
                "id": entry["id"],
                "repository": entry["repo"],
                "status": "skipped-existing-no-metadata",
                "snapshotPath": str(destination),
            }
        shutil.rmtree(destination)

    work_parent = Path(tempfile.mkdtemp(prefix=f"{entry['id']}-", dir=str(out_root)))
    repo_dir = work_parent / "repo"
    env = os.environ.copy()
    if not fetch_lfs_content:
        env["GIT_LFS_SKIP_SMUDGE"] = "1"
    try:
        run(
            [
                "git",
                "clone",
                "--filter=blob:none",
                "--no-checkout",
                "--depth",
                "1",
                "--branch",
                entry["default_branch"],
                entry["clone_url"],
                str(repo_dir),
            ],
            env=env,
        )
        run(["git", "config", "core.autocrlf", "false"], cwd=repo_dir)
        run(["git", "sparse-checkout", "init", "--no-cone"], cwd=repo_dir)
        sparse_file = repo_dir / ".git" / "info" / "sparse-checkout"
        sparse_file.write_text("\n".join(corpus_sparse_patterns()) + "\n", encoding="utf-8")
        run(["git", "checkout", "-f", "--quiet"], cwd=repo_dir)
        commit = run(["git", "rev-parse", "HEAD"], cwd=repo_dir)

        removed_large_files = apply_file_size_cap(repo_dir, max_file_bytes=max_file_bytes)
        paclet_extractions = extract_paclets(repo_dir) if extract_paclets_flag else []
        files = iter_snapshot_files(repo_dir)
        matched_files = [path for path in files if path.suffix.lower() in CORPUS_EXTENSIONS]
        if not matched_files:
            return {
                "id": entry["id"],
                "repository": entry["repo"],
                "status": "skipped-no-matches",
                "discoveryKind": entry["discovery_kind"],
                "discoveryReason": entry["discovery_reason"],
            }

        remove_git_dir(repo_dir)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(repo_dir), str(destination))

        final_files = iter_snapshot_files(destination)
        all_histogram, matched_histogram, total_bytes, matched_bytes = repository_histograms(final_files, destination)
        snapshot = {
            "id": entry["id"],
            "repository": entry["repo"],
            "cloneUrl": entry["clone_url"],
            "defaultBranch": entry["default_branch"],
            "commit": commit,
            "status": "downloaded",
            "discoveryKind": entry["discovery_kind"],
            "discoveryReason": entry["discovery_reason"],
            "description": entry.get("description"),
            "license": entry.get("license"),
            "pushedAt": entry.get("pushed_at"),
            "snapshotPath": str(destination),
            "generatedUtc": utc_now_iso(),
            "fileCount": len(final_files),
            "matchedFileCount": len([path for path in final_files if path.suffix.lower() in CORPUS_EXTENSIONS]),
            "fileCountByExtension": all_histogram,
            "matchedFileCountByExtension": matched_histogram,
            "totalBytes": total_bytes,
            "matchedBytes": matched_bytes,
            "removedLargeFiles": removed_large_files,
            "pacletExtractions": paclet_extractions,
        }
        (destination / ".snapshot.json").write_text(json.dumps(snapshot, indent=2), encoding="utf-8")
        return snapshot
    finally:
        if work_parent.exists():
            shutil.rmtree(work_parent, ignore_errors=True)


def notebook_archive_object_url(short_name: str) -> str:
    year, month, _rest = short_name.split("-", 2)
    return f"https://www.wolframcloud.com/objects/nbarch/{year}/{month}/{short_name}/{short_name}.nb"


def notebook_archive_download_url(object_url: str) -> str:
    api_url = (
        "https://www.wolframcloud.com/obj/nbarch/api/uuid?obj="
        + urllib.parse.quote(object_url, safe="")
    )
    payload = fetch_json(api_url)
    url = payload.get("url")
    if not isinstance(url, str) or not url.startswith("http"):
        raise ValueError(f"Notebook Archive resolver did not return a downloadable URL: {payload!r}")
    return url


def download_notebook_archive_entry(
    entry: dict[str, Any],
    *,
    bucket: str,
    out_root: Path,
    force: bool,
) -> dict[str, Any]:
    short_name = entry["ShortName"]
    destination = out_root / bucket / f"{short_name}.nb"
    object_url = notebook_archive_object_url(short_name)
    metadata = {
        "id": short_name,
        "bucket": bucket,
        "title": entry.get("Title") or entry.get("SourceMetadata", {}).get("Title"),
        "authors": entry.get("SourceMetadata", {}).get("AuthorFullName")
        or entry.get("SourceMetadata", {}).get("Author")
        or [],
        "categories": entry.get("Categories") or [],
        "pageBadge": entry.get("PageBadge") or [],
        "creationDate": entry.get("NotebookMetadata", {}).get("CreationDate"),
        "submissionDate": entry.get("NotebookMetadata", {}).get("SubmissionDate"),
        "lastModifiedDate": entry.get("NotebookMetadata", {}).get("LastModifiedDate"),
        "objectUrl": object_url,
        "path": str(destination).replace("\\", "/"),
    }
    if destination.exists() and not force:
        metadata["status"] = "kept-existing"
        metadata["bytes"] = destination.stat().st_size
        return metadata
    download_url = notebook_archive_download_url(object_url)
    payload = download_bytes(download_url)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(payload)
    metadata["status"] = "downloaded"
    metadata["bytes"] = len(payload)
    return metadata


def load_notebook_archive_index(bucket: str) -> dict[str, Any]:
    return fetch_json(NOTEBOOK_ARCHIVE_INDEXES[bucket])


def materialize_notebook_archive(
    *,
    out_root: Path,
    force: bool,
    include_historical: bool,
    workers: int,
) -> dict[str, Any]:
    archive_root = out_root / "notebookarchive"
    archive_root.mkdir(parents=True, exist_ok=True)
    indexes_root = archive_root / "indexes"
    indexes_root.mkdir(parents=True, exist_ok=True)

    bucket_order = ["non_historical"] + (["historical"] if include_historical else [])
    index_snapshots: dict[str, Any] = {}
    for bucket in bucket_order:
        payload = load_notebook_archive_index(bucket)
        index_snapshots[bucket] = payload
        (indexes_root / f"{bucket}.json").write_text(json.dumps(payload, indent=2), encoding="utf-8")

    raw_entries: list[tuple[str, dict[str, Any]]] = []
    skipped_collections: list[str] = []
    for bucket in bucket_order:
        for entry in index_snapshots[bucket].get("Resources", []):
            if entry.get("Collection"):
                skipped_collections.append(entry["ShortName"])
                continue
            raw_entries.append((bucket, entry))

    results: list[dict[str, Any]] = []
    failures: list[dict[str, Any]] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, workers)) as executor:
        future_map = {
            executor.submit(
                download_notebook_archive_entry,
                entry,
                bucket=bucket,
                out_root=archive_root,
                force=force,
            ): (bucket, entry)
            for bucket, entry in raw_entries
        }
        for future in concurrent.futures.as_completed(future_map):
            bucket, entry = future_map[future]
            try:
                results.append(future.result())
            except Exception as exc:  # noqa: BLE001
                failures.append(
                    {
                        "id": entry.get("ShortName"),
                        "bucket": bucket,
                        "status": "failed",
                        "error": str(exc),
                    }
                )

    results.sort(key=lambda item: (item["bucket"], item["id"]))
    failures.sort(key=lambda item: (item["bucket"], item["id"]))
    bucket_counts = Counter(item["bucket"] for item in results)
    bucket_bytes = Counter()
    for item in results:
        bucket_bytes[item["bucket"]] += int(item.get("bytes") or 0)

    manifest = {
        "source": "Notebook Archive",
        "status": "downloaded" if not failures else "downloaded-with-failures",
        "generatedUtc": utc_now_iso(),
        "root": str(archive_root),
        "includedBuckets": bucket_order,
        "indexUrls": {bucket: NOTEBOOK_ARCHIVE_INDEXES[bucket] for bucket in bucket_order},
        "indexCounts": {
            bucket: {
                "resourceCount": len(index_snapshots[bucket].get("Resources", [])),
                "information": index_snapshots[bucket].get("Information", {}),
            }
            for bucket in bucket_order
        },
        "downloadedNotebookCount": len(results),
        "downloadedNotebookCountByBucket": dict(sorted(bucket_counts.items())),
        "downloadedBytesByBucket": dict(sorted(bucket_bytes.items())),
        "skippedCollectionEntries": skipped_collections,
        "failedDownloads": failures,
        "downloads": results,
    }
    (archive_root / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    return manifest


def render_readme(
    *,
    out_root: Path,
    github_snapshots: list[dict[str, Any]],
    excluded_repositories: list[dict[str, Any]],
    notebook_archive_manifest: dict[str, Any] | None,
    manifest_path: Path,
) -> str:
    lines: list[str] = []
    lines.append("# Tungsten Wolfram parser corpus")
    lines.append("")
    lines.append(f"Generated (UTC): {utc_now_iso()}")
    lines.append("")
    lines.append(
        "This directory contains a large local-only parser corpus of public Wolfram notebooks, packages,"
    )
    lines.append(
        " paclets, and related source files fetched from GitHub and the Notebook Archive."
    )
    lines.append("")
    lines.append("Use intent:")
    lines.append("")
    lines.append(
        "- The intended use here is to parse this code locally as corpus input for Tungsten."
    )
    lines.append("- The intended use is not to modify the fetched third-party code, create derivative works from it, bundle it with Tungsten, or redistribute it from this workspace.")
    lines.append("")
    lines.append("Refresh command:")
    lines.append("")
    lines.append("```powershell")
    lines.append(
        r"pwsh -File C:\Tools3\Tools\src\Tungsten\scripts\Acquire-TungstenWolframParserCorpus.ps1 -Force"
    )
    lines.append("```")
    lines.append("")
    lines.append("Notes:")
    lines.append("")
    lines.append("- GitHub snapshots preserve root `LICENSE*`/`COPYING*`/`README*` files when present.")
    lines.append("- Only Wolfram notebook/package-ish file types are materialized from GitHub snapshots.")
    lines.append("- Notebook Archive notebooks are fetched through the archive's own published index JSON and download API.")
    lines.append("- Notebook Archive rights vary by entry; consult the original archive page for per-notebook rights metadata.")
    lines.append("- This corpus is intentionally outside the repository so it can stay large and non-redistributed.")
    lines.append("")
    lines.append("## GitHub snapshots")
    lines.append("")
    lines.append("| Id | Repository | Commit | License | Discovery | Matched files |")
    lines.append("| --- | --- | --- | --- | --- | ---: |")
    for snapshot in github_snapshots:
        if snapshot.get("status") != "downloaded":
            continue
        license_name = snapshot.get("license") or "unknown"
        lines.append(
            "| "
            + snapshot["id"]
            + " | `"
            + snapshot["repository"]
            + "` | `"
            + snapshot["commit"]
            + "` | "
            + license_name
            + " | "
            + snapshot.get("discoveryKind", "unknown")
            + " | "
            + str(snapshot.get("matchedFileCount", 0))
            + " |"
        )
    if excluded_repositories:
        lines.append("")
        lines.append("## Excluded discovery candidates")
        lines.append("")
        for excluded in excluded_repositories:
            lines.append(f"- `{excluded['repo']}`: {excluded['reason']}")
    if notebook_archive_manifest:
        lines.append("")
        lines.append("## Notebook Archive")
        lines.append("")
        lines.append(
            f"- Downloaded notebooks: {notebook_archive_manifest['downloadedNotebookCount']}"
        )
        for bucket, count in notebook_archive_manifest["downloadedNotebookCountByBucket"].items():
            lines.append(f"- `{bucket}`: {count} notebooks")
        if notebook_archive_manifest["failedDownloads"]:
            lines.append(
                f"- Failed downloads: {len(notebook_archive_manifest['failedDownloads'])}"
            )
        if notebook_archive_manifest["skippedCollectionEntries"]:
            lines.append(
                f"- Skipped collection entries: {len(notebook_archive_manifest['skippedCollectionEntries'])}"
            )
    lines.append("")
    lines.append(f"Machine-readable manifest: `{manifest_path}`")
    lines.append(f"Corpus root: `{out_root}`")
    return "\n".join(lines) + "\n"


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Acquire a large Wolfram parser corpus for Tungsten.")
    parser.add_argument(
        "--out",
        type=Path,
        default=Path(r"C:\TestData\tungsten-wolfram-parser-corpus"),
        help="Output directory.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Re-download and overwrite existing snapshots or archive files.",
    )
    parser.add_argument(
        "--skip-github",
        action="store_true",
        help="Skip GitHub corpus acquisition.",
    )
    parser.add_argument(
        "--skip-notebook-archive",
        action="store_true",
        help="Skip Notebook Archive acquisition.",
    )
    parser.add_argument(
        "--skip-historical-notebook-archive",
        action="store_true",
        help="Only fetch the non-historical Notebook Archive bucket.",
    )
    parser.add_argument(
        "--max-discovered-repositories",
        type=int,
        default=24,
        help="Maximum number of non-curated repositories to add from GitHub discovery.",
    )
    parser.add_argument(
        "--max-discovered-repo-size-mb",
        type=int,
        default=512,
        help="Skip discovered GitHub repositories larger than this approximate size.",
    )
    parser.add_argument(
        "--max-file-mb",
        type=int,
        default=64,
        help="Drop individual GitHub snapshot files larger than this size after checkout.",
    )
    parser.add_argument(
        "--no-extract-paclets",
        action="store_true",
        help="Keep `.paclet` files without extracting parser-relevant contents.",
    )
    parser.add_argument(
        "--fetch-lfs-content",
        action="store_true",
        help="Allow Git LFS blobs to materialize during GitHub checkout.",
    )
    parser.add_argument(
        "--github-token",
        default=os.environ.get("GITHUB_TOKEN", "").strip(),
        help="Optional GitHub token. Defaults to `GITHUB_TOKEN` when present.",
    )
    parser.add_argument(
        "--notebook-archive-workers",
        type=int,
        default=12,
        help="Concurrent Notebook Archive download workers.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    out_root = args.out.resolve()
    out_root.mkdir(parents=True, exist_ok=True)
    manifest_path = out_root / "manifest.json"
    existing_manifest: dict[str, Any] = {}
    if manifest_path.exists():
        try:
            existing_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            existing_manifest = {}

    manifest: dict[str, Any] = {
        "generatedUtc": utc_now_iso(),
        "outDir": str(out_root),
        "purpose": "Local-only Wolfram parser corpus for Tungsten.",
        "localUseOnly": True,
        "github": existing_manifest.get("github", {}),
        "notebookArchive": existing_manifest.get("notebookArchive", {}),
    }

    github_snapshots: list[dict[str, Any]] = []
    excluded_repositories: list[dict[str, Any]] = []

    if not args.skip_github:
        github_root = out_root / "github"
        github_root.mkdir(parents=True, exist_ok=True)
        included_repositories, excluded_repositories = prepare_repository_candidates(
            token=args.github_token or None,
            max_discovered_repositories=args.max_discovered_repositories,
            max_discovered_repo_size_kb=args.max_discovered_repo_size_mb * 1024,
        )
        for entry in included_repositories:
            print(f"==> GitHub: {entry['repo']}", file=sys.stderr)
            try:
                snapshot = materialize_repository(
                    entry,
                    out_root=github_root,
                    force=args.force,
                    fetch_lfs_content=args.fetch_lfs_content,
                    extract_paclets_flag=not args.no_extract_paclets,
                    max_file_bytes=args.max_file_mb * 1024 * 1024,
                )
            except Exception as exc:  # noqa: BLE001
                error_text = getattr(exc, "stdout", None) or getattr(exc, "output", None) or str(exc)
                snapshot = {
                    "id": entry["id"],
                    "repository": entry["repo"],
                    "status": "failed",
                    "discoveryKind": entry["discovery_kind"],
                    "discoveryReason": entry["discovery_reason"],
                    "error": error_text.strip() if isinstance(error_text, str) else str(error_text),
                }
            github_snapshots.append(snapshot)
            status = snapshot.get("status", "unknown")
            if status == "downloaded":
                print(
                    f"    -> {snapshot['matchedFileCount']} matched files at {snapshot['snapshotPath']}",
                    file=sys.stderr,
                )
            else:
                print(f"    -> {status}", file=sys.stderr)

        github_downloaded = [snap for snap in github_snapshots if snap.get("status") == "downloaded"]
        manifest["github"] = {
            "status": "downloaded" if len(github_downloaded) == len(github_snapshots) else "downloaded-with-failures",
            "repositoryCount": len(github_downloaded),
            "candidateCount": len(github_snapshots),
            "matchedFileCount": sum(int(snap.get("matchedFileCount", 0)) for snap in github_downloaded),
            "matchedBytes": sum(int(snap.get("matchedBytes", 0)) for snap in github_downloaded),
            "repositories": github_snapshots,
            "excludedDiscoveryCandidates": excluded_repositories,
        }

    notebook_archive_manifest: dict[str, Any] | None = None
    if not args.skip_notebook_archive:
        print("==> Notebook Archive", file=sys.stderr)
        notebook_archive_manifest = materialize_notebook_archive(
            out_root=out_root,
            force=args.force,
            include_historical=not args.skip_historical_notebook_archive,
            workers=args.notebook_archive_workers,
        )
        print(
            f"    -> {notebook_archive_manifest['downloadedNotebookCount']} notebooks",
            file=sys.stderr,
        )
        manifest["notebookArchive"] = notebook_archive_manifest

    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")

    readme_github_snapshots = github_snapshots or manifest.get("github", {}).get("repositories", [])
    readme_excluded_repositories = excluded_repositories or manifest.get("github", {}).get("excludedDiscoveryCandidates", [])
    readme_notebook_archive = notebook_archive_manifest or manifest.get("notebookArchive") or None

    readme_path = out_root / "README.md"
    readme_path.write_text(
        render_readme(
            out_root=out_root,
            github_snapshots=readme_github_snapshots,
            excluded_repositories=readme_excluded_repositories,
            notebook_archive_manifest=readme_notebook_archive,
            manifest_path=manifest_path,
        ),
        encoding="utf-8",
    )

    print("", file=sys.stderr)
    print(f"Wrote manifest: {manifest_path}", file=sys.stderr)
    print(f"Wrote README:   {readme_path}", file=sys.stderr)
    print(f"Corpus root:    {out_root}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
