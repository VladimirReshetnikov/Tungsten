from __future__ import annotations

import argparse
import json
import re
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


TEXT_EXTENSIONS = {
    ".c",
    ".cc",
    ".cpp",
    ".cs",
    ".go",
    ".h",
    ".hpp",
    ".hs",
    ".html",
    ".java",
    ".jl",
    ".js",
    ".json",
    ".m",
    ".markdown",
    ".md",
    ".mt",
    ".py",
    ".rb",
    ".rs",
    ".scala",
    ".sh",
    ".toml",
    ".txt",
    ".wl",
    ".wls",
    ".xml",
    ".yaml",
    ".yml",
}

MAX_TEXT_BYTES = 4_000_000
EXCLUDED_BASENAME_PATTERNS = (
    re.compile(r"^\.snapshot", re.IGNORECASE),
    re.compile(r"^readme(?:\..+)?$", re.IGNORECASE),
    re.compile(r"^license(?:\..+)?$", re.IGNORECASE),
    re.compile(r"^copying(?:\..+)?$", re.IGNORECASE),
    re.compile(r"^notice(?:\..+)?$", re.IGNORECASE),
)

TAG_PATTERNS: dict[str, tuple[str, ...]] = {
    "parser": (
        r"\bparse(?:r|rs|d|s|ing)?\b",
        r"\bparser\b",
        r"\bsyntax\b",
        r"\bprecedence\b",
        r"\boperator(?:s| table)?\b",
        r"\btoken(?:izer|iser|s)?\b",
        r"\blexer\b",
        r"\bscanner\b",
        r"\binputform\b",
        r"\bfullform\b",
        r"\bstandardform\b",
    ),
    "box": (
        r"\bboxdata\b",
        r"\browbox\b",
        r"\btagbox\b",
        r"\bformbox\b",
        r"\bstylebox\b",
        r"\btemplatebox\b",
        r"\bgridbox\b",
        r"\binterpretationbox\b",
        r"\btooltipbox\b",
        r"\bfractionbox\b",
        r"\bsqrtbox\b",
        r"\bradicalbox\b",
        r"\bsuperscriptbox\b",
        r"\bsubscriptbox\b",
        r"\bsubsuperscriptbox\b",
        r"\boverscriptbox\b",
        r"\bunderscriptbox\b",
        r"\b[a-z][a-z0-9]*box\b",
        r"\\\[[A-Za-z][A-Za-z0-9]*\]",
    ),
    "pattern": (
        r"\bpattern\b",
        r"\bblank(?:sequence|nullsequence)?\b",
        r"\bmatchq\b",
        r"\bfreeq\b",
        r"\bcases\b",
        r"\bdeletecases\b",
        r"\breplace(?:all|repeated|part|at)?\b",
        r"\bruledelayed\b",
        r"\bcondition\b",
        r"\balternatives\b",
        r"\bexcept\b",
        r"\bholdpattern\b",
        r"\bverbatim\b",
        r"/\\.",
        r"//\\.",
    ),
    "functional": (
        r"\bfunction\b",
        r"\bslot(?:sequence)?\b",
        r"\bcomposition\b",
        r"\brightcomposition\b",
        r"\bfixedpoint(?:list)?\b",
        r"\bnest(?:list|while|whilelist)?\b",
        r"\bfold(?:list|while|whilelist|pair|pairlist)?\b",
        r"\bmap(?:all|indexed|apply|at|thread)?\b",
        r"\bapply\b",
        r"\bscan\b",
        r"\bthrough\b",
        r"\bthread\b",
        r"\boperator form\b",
    ),
    "control_flow": (
        r"\bif\b",
        r"\bwhich\b",
        r"\bswitch\b",
        r"\bpiecewise\b",
        r"\bfor\b",
        r"\bwhile\b",
        r"\bdo\b",
        r"\bbreak\b",
        r"\bcontinue\b",
        r"\breturn\b",
        r"\bcatch\b",
        r"\bthrow\b",
        r"\breap\b",
        r"\bsow\b",
    ),
    "scoping": (
        r"\bblock\b",
        r"\bmodule\b",
        r"\bwith\b",
        r"\bscop(?:e|ing)\b",
        r"\blexical\b",
        r"\bdynamic\b",
    ),
    "associations": (
        r"\bassociation\b",
        r"\blookup\b",
        r"\bkeys\b",
        r"\bvalues\b",
        r"\bnormal\b",
        r"\bkey(?:take|drop|map|valuemap|existsq|memberq)\b",
        r"\bassociation(?:thread|map)\b",
    ),
    "arrays": (
        r"\barray\b",
        r"\bconstantarray\b",
        r"\bunitvector\b",
        r"\bidentitymatrix\b",
        r"\bdiagonalmatrix\b",
        r"\bpartition\b",
        r"\bblockmap\b",
        r"\btakelist\b",
        r"\btakedrop\b",
        r"\bflatten\b",
        r"\binner\b",
        r"\bouter\b",
        r"\bdot\b",
        r"\btuple(?:s)?\b",
        r"\bvector\b",
        r"\bmatrix\b",
        r"\btensor\b",
        r"\bmapthread\b",
        r"\btranspose\b",
    ),
    "sparse_arrays": (
        r"\bsparsearray\b",
        r"\bsparse\b",
        r"\bband\b",
    ),
    "basic_integer": (
        r"\bgcd\b",
        r"\blcm\b",
        r"\bdivis(?:or|ors)\b",
        r"\bmod\b",
        r"\bquotient(?:remainder)?\b",
        r"\bunitstep\b",
        r"\bclip\b",
        r"\bkroneckerdelta\b",
        r"\bdiscretedelta\b",
        r"\bevenq\b",
        r"\boddq\b",
        r"\bsign\b",
        r"\babs\b",
        r"\bramp\b",
        r"\bintegerq\b",
    ),
    "floating_point": (
        r"\bfloat(?:ing)?\b",
        r"\breal\b",
        r"\bmachineprecision\b",
        r"\bround\b",
        r"\bfloor\b",
        r"\bceiling\b",
        r"\bprecision\b",
    ),
    "borderline_numeric": (
        r"\bfactorinteger\b",
        r"\beulerphi\b",
        r"\bfibonacci\b",
        r"\bintegerexponent\b",
        r"\bdivisible\b",
        r"\bprime(?:pi|q|omega|nu)?\b",
        r"\bnextprime\b",
        r"\bmoebiusmu\b",
        r"\bmangoldtlambda\b",
        r"\bjacobisymbol\b",
        r"\blegendre\b",
        r"\bbinomial\b",
        r"\bfactorial(?:2)?\b",
    ),
    "out_of_scope_math": (
        r"\bsin\b",
        r"\bcos\b",
        r"\btan\b",
        r"\bcot\b",
        r"\bsec\b",
        r"\bcsc\b",
        r"\bsinh\b",
        r"\bcosh\b",
        r"\btanh\b",
        r"\bexp\b",
        r"\blog\b",
        r"\bgamma\b",
        r"\bbessel\b",
        r"\bhypergeometric\b",
        r"\bairy\b",
        r"\bzeta\b",
        r"\berf\b",
        r"\bintegr(?:al|ate)\b",
        r"\bderiv(?:ative|atives)?\b",
        r"\bdsolve\b",
        r"\bn?solve\b",
        r"\breduce\b",
        r"\bfindroot\b",
        r"\bsimplify\b",
        r"\bfullsimplify\b",
        r"\bexpand\b",
        r"\bfactor\b",
        r"\bcollect\b",
        r"\bpolynomial\b",
        r"\bgroebner\b",
        r"\bresultant\b",
        r"\bminimi[sz]e\b",
        r"\bmaximi[sz]e\b",
        r"\bnminimi[sz]e\b",
        r"\bnmaximi[sz]e\b",
        r"\boptim(?:ize|isation|ization)?\b",
        r"\beigen(?:system|values|vectors)\b",
        r"\blinearsolve\b",
        r"\bdeterminant\b",
        r"\binverse\b",
        r"\bplot(?:3d)?\b",
        r"\bgraphics(?:3d)?\b",
    ),
}

TAG_ORDER = (
    "parser",
    "box",
    "pattern",
    "functional",
    "control_flow",
    "scoping",
    "associations",
    "arrays",
    "sparse_arrays",
    "basic_integer",
    "floating_point",
    "borderline_numeric",
    "out_of_scope_math",
)

COMPILED_TAG_PATTERNS = {
    tag: tuple(re.compile(pattern, re.IGNORECASE) for pattern in patterns)
    for tag, patterns in TAG_PATTERNS.items()
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Analyze the downloaded Tungsten upstream Wolfram-language test corpus."
    )
    parser.add_argument(
        "--corpus-root",
        type=Path,
        default=Path(r"C:\TestData\tungsten-wolfram-upstream-tests"),
        help="Corpus root created by Acquire-TungstenWolframUpstreamTests.ps1.",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        help="Optional explicit path to the corpus manifest JSON file.",
    )
    parser.add_argument(
        "--top",
        type=int,
        default=10,
        help="How many top files to include per repository/category.",
    )
    parser.add_argument(
        "--json-out",
        type=Path,
        help="Optional path to write the analysis JSON payload.",
    )
    return parser.parse_args()


def load_manifest(corpus_root: Path, manifest_path: Path | None) -> dict[str, Any]:
    resolved_manifest = manifest_path or (corpus_root / "manifest.json")
    return json.loads(resolved_manifest.read_text(encoding="utf-8"))


def is_text_like(path: Path) -> bool:
    return path.suffix.lower() in TEXT_EXTENSIONS


def should_analyze_file(path: Path) -> bool:
    name = path.name
    return not any(pattern.match(name) for pattern in EXCLUDED_BASENAME_PATTERNS)


def read_text_payload(path: Path) -> str:
    try:
        size = path.stat().st_size
    except OSError:
        return ""

    if size > MAX_TEXT_BYTES or not is_text_like(path):
        return ""

    try:
        return path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return ""


def score_tags(path: Path, text: str) -> dict[str, int]:
    haystack = f"{path.as_posix().lower()}\n{text.lower()}"
    scores: dict[str, int] = {}
    for tag, patterns in COMPILED_TAG_PATTERNS.items():
        score = 0
        for pattern in patterns:
            if pattern.search(haystack):
                score += 1
        scores[tag] = score
    return scores


def evaluator_scope_score(tag_scores: dict[str, int]) -> int:
    return sum(
        tag_scores[tag]
        for tag in (
            "pattern",
            "functional",
            "control_flow",
            "scoping",
            "associations",
            "arrays",
            "sparse_arrays",
            "basic_integer",
            "floating_point",
        )
    )


def classify_file(tag_scores: dict[str, int]) -> tuple[list[str], int, int]:
    parser_score = tag_scores["parser"] + tag_scores["box"]
    evaluator_score = evaluator_scope_score(tag_scores)
    out_of_scope_score = tag_scores["out_of_scope_math"]
    classes: list[str] = []

    if parser_score >= 2:
        classes.append("parser")
    if tag_scores["box"] >= 2:
        classes.append("box-parser")
    if evaluator_score >= 4 and out_of_scope_score == 0:
        classes.append("evaluator")
    elif evaluator_score >= 4 and out_of_scope_score > 0:
        classes.append("mixed-evaluator")
    elif out_of_scope_score >= 4 and evaluator_score < 4:
        classes.append("mostly-out-of-scope")

    return classes, parser_score, evaluator_score


def choose_top_files(
    file_records: list[dict[str, Any]],
    *,
    predicate: Any,
    sort_key: Any,
    limit: int,
) -> list[dict[str, Any]]:
    filtered = [record for record in file_records if predicate(record)]
    filtered.sort(key=sort_key, reverse=True)
    top = []
    for record in filtered[:limit]:
        top.append(
            {
                "path": record["relative_path"],
                "parserScore": record["parser_score"],
                "evaluatorScore": record["evaluator_score"],
                "outOfScopeScore": record["tag_scores"]["out_of_scope_math"],
                "borderlineNumericScore": record["tag_scores"]["borderline_numeric"],
                "tags": record["matched_tags"],
            }
        )
    return top


def analyze_repository(repo: dict[str, Any], top_n: int) -> dict[str, Any]:
    snapshot_root = Path(repo["snapshotPath"])
    file_records: list[dict[str, Any]] = []
    tag_histogram: Counter[str] = Counter()

    for path in snapshot_root.rglob("*"):
        if not path.is_file():
            continue
        if ".git" in path.parts:
            continue
        if not should_analyze_file(path):
            continue
        text = read_text_payload(path)
        tag_scores = score_tags(path.relative_to(snapshot_root), text)
        matched_tags = [tag for tag in TAG_ORDER if tag_scores[tag] > 0]
        for tag in matched_tags:
            tag_histogram[tag] += 1

        classes, parser_score, evaluator_score = classify_file(tag_scores)
        file_records.append(
            {
                "relative_path": path.relative_to(snapshot_root).as_posix(),
                "matched_tags": matched_tags,
                "classes": classes,
                "parser_score": parser_score,
                "evaluator_score": evaluator_score,
                "tag_scores": tag_scores,
            }
        )

    parser_files = [record for record in file_records if "parser" in record["classes"]]
    box_files = [record for record in file_records if "box-parser" in record["classes"]]
    evaluator_files = [record for record in file_records if "evaluator" in record["classes"]]
    mixed_files = [record for record in file_records if "mixed-evaluator" in record["classes"]]
    out_files = [record for record in file_records if "mostly-out-of-scope" in record["classes"]]

    return {
        "id": repo["id"],
        "repository": repo["repository"],
        "license": repo["license"],
        "commit": repo["commit"],
        "snapshotPath": repo["snapshotPath"],
        "totalFilesSeen": len(file_records),
        "parserCandidateCount": len(parser_files),
        "boxCandidateCount": len(box_files),
        "evaluatorCandidateCount": len(evaluator_files),
        "mixedEvaluatorCandidateCount": len(mixed_files),
        "mostlyOutOfScopeCount": len(out_files),
        "tagHistogram": {tag: tag_histogram.get(tag, 0) for tag in TAG_ORDER if tag_histogram.get(tag, 0) > 0},
        "topParserFiles": choose_top_files(
            file_records,
            predicate=lambda record: "parser" in record["classes"],
            sort_key=lambda record: (
                record["parser_score"],
                record["tag_scores"]["box"],
                record["evaluator_score"],
            ),
            limit=top_n,
        ),
        "topBoxFiles": choose_top_files(
            file_records,
            predicate=lambda record: "box-parser" in record["classes"],
            sort_key=lambda record: (
                record["tag_scores"]["box"],
                record["parser_score"],
            ),
            limit=top_n,
        ),
        "topEvaluatorFiles": choose_top_files(
            file_records,
            predicate=lambda record: "evaluator" in record["classes"],
            sort_key=lambda record: (
                record["evaluator_score"],
                record["tag_scores"]["pattern"],
                record["tag_scores"]["functional"],
                record["tag_scores"]["control_flow"],
            ),
            limit=top_n,
        ),
        "topMixedFiles": choose_top_files(
            file_records,
            predicate=lambda record: "mixed-evaluator" in record["classes"],
            sort_key=lambda record: (
                record["evaluator_score"],
                -record["tag_scores"]["out_of_scope_math"],
            ),
            limit=top_n,
        ),
        "topMostlyOutOfScopeFiles": choose_top_files(
            file_records,
            predicate=lambda record: "mostly-out-of-scope" in record["classes"],
            sort_key=lambda record: (
                record["tag_scores"]["out_of_scope_math"],
                record["parser_score"],
            ),
            limit=top_n,
        ),
    }


def build_summary(repositories: list[dict[str, Any]]) -> dict[str, Any]:
    def rank_by(*keys: str) -> list[dict[str, Any]]:
        ranked = sorted(
            repositories,
            key=lambda repo: tuple(repo[key] for key in keys),
            reverse=True,
        )
        return [
            {
                "id": repo["id"],
                "repository": repo["repository"],
                "license": repo["license"],
                "parserCandidateCount": repo["parserCandidateCount"],
                "boxCandidateCount": repo["boxCandidateCount"],
                "evaluatorCandidateCount": repo["evaluatorCandidateCount"],
                "mixedEvaluatorCandidateCount": repo["mixedEvaluatorCandidateCount"],
                "mostlyOutOfScopeCount": repo["mostlyOutOfScopeCount"],
            }
            for repo in ranked
        ]

    return {
        "parserRichRepositories": rank_by("parserCandidateCount", "boxCandidateCount", "evaluatorCandidateCount"),
        "boxRichRepositories": rank_by("boxCandidateCount", "parserCandidateCount", "evaluatorCandidateCount"),
        "evaluatorRichRepositories": rank_by(
            "evaluatorCandidateCount",
            "mixedEvaluatorCandidateCount",
            "parserCandidateCount",
        ),
        "mixedRepositories": rank_by("mixedEvaluatorCandidateCount", "evaluatorCandidateCount"),
    }


def main() -> int:
    args = parse_args()
    manifest = load_manifest(args.corpus_root, args.manifest)
    repositories = [analyze_repository(repo, args.top) for repo in manifest["repositories"]]
    payload = {
        "generatedUtc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "corpusRoot": str(args.corpus_root),
        "repositoryCount": len(repositories),
        "tagRules": {tag: list(patterns) for tag, patterns in TAG_PATTERNS.items()},
        "summary": build_summary(repositories),
        "repositories": repositories,
    }

    rendered = json.dumps(payload, indent=2)
    if args.json_out is not None:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(rendered + "\n", encoding="utf-8")
    else:
        print(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
