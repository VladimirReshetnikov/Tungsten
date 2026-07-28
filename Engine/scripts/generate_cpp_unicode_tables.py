#!/usr/bin/env python3
"""Generate deterministic C++ Unicode tables from the Python Engine oracle.

The emitted data covers every Unicode scalar value.  Case mappings use the
full result of ``str.upper`` and ``str.lower``, including one-to-many mappings.
The Cased and Case_Ignorable properties needed for Final_Sigma are inferred
from Python's observable lowercasing behavior, keeping the generator tied to
the compatibility oracle rather than a separately versioned data source.
"""

from __future__ import annotations

import argparse
from collections import defaultdict
import sys
import unicodedata
from collections.abc import Callable, Iterable


MAX_CODE_POINT = 0x10FFFF
SURROGATE_FIRST = 0xD800
SURROGATE_LAST = 0xDFFF
EXPECTED_CPYTHON = (3, 13, 14)
EXPECTED_UNICODE = "15.1.0"


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--allow-version-change",
        action="store_true",
        help=(
            "generate from the active interpreter even when its CPython or "
            "Unicode version differs from the repository pin"
        ),
    )
    return parser.parse_args()


def require_pinned_runtime(*, allow_version_change: bool) -> None:
    actual_cpython = sys.version_info[:3]
    actual_unicode = unicodedata.unidata_version
    if (
        actual_cpython == EXPECTED_CPYTHON
        and actual_unicode == EXPECTED_UNICODE
    ) or allow_version_change:
        return
    expected_python = ".".join(map(str, EXPECTED_CPYTHON))
    actual_python = ".".join(map(str, actual_cpython))
    raise SystemExit(
        "refusing to regenerate Unicode tables with an unpinned runtime: "
        f"expected CPython {expected_python} / Unicode {EXPECTED_UNICODE}, "
        f"found CPython {actual_python} / Unicode {actual_unicode}; "
        "use --allow-version-change only for an intentional table upgrade"
    )


def scalar_values() -> Iterable[int]:
    return (
        value
        for value in range(MAX_CODE_POINT + 1)
        if not SURROGATE_FIRST <= value <= SURROGATE_LAST
    )


def property_ranges(predicate: Callable[[int], bool]) -> list[tuple[int, int]]:
    ranges: list[tuple[int, int]] = []
    first: int | None = None
    previous: int | None = None
    for value in scalar_values():
        if predicate(value):
            if first is None or previous is None or value != previous + 1:
                if first is not None and previous is not None:
                    ranges.append((first, previous))
                first = value
            previous = value
        elif first is not None and previous is not None:
            ranges.append((first, previous))
            first = None
            previous = None
    if first is not None and previous is not None:
        ranges.append((first, previous))
    return ranges


def case_entries(
    transform: Callable[[str], str],
) -> tuple[list[tuple[int, int, int, int]], list[tuple[int, tuple[int, ...]]]]:
    simple: list[tuple[int, int]] = []
    multiple: list[tuple[int, tuple[int, ...]]] = []
    for value in scalar_values():
        targets = tuple(ord(character) for character in transform(chr(value)))
        if targets == (value,):
            continue
        if len(targets) == 1:
            simple.append((value, targets[0] - value))
        else:
            multiple.append((value, targets))

    ranges, single_mappings = compress_simple_entries(simple)
    return ranges, sorted(single_mappings + multiple)


def compress_simple_entries(
    simple: list[tuple[int, int]],
) -> tuple[
    list[tuple[int, int, int, int]],
    list[tuple[int, tuple[int, ...]]],
]:
    ranges: list[tuple[int, int, int, int]] = []
    single_mappings: list[tuple[int, tuple[int, ...]]] = []
    index = 0
    while index < len(simple):
        value, delta = simple[index]
        best_end = index + 1
        best_step = 0
        for step in (1, 2):
            end = index + 1
            while (
                end < len(simple)
                and simple[end][0] == simple[end - 1][0] + step
                and simple[end][1] == delta
            ):
                end += 1
            if end - index >= 2 and end > best_end:
                best_end = end
                best_step = step
        if best_step:
            ranges.append((value, simple[best_end - 1][0], best_step, delta))
            index = best_end
        else:
            single_mappings.append((value, (value + delta,)))
            index += 1
    return ranges, single_mappings


def regex_case_entries() -> tuple[
    list[tuple[int, int, int, int]],
    list[tuple[int, tuple[int, ...]]],
    list[tuple[int, tuple[int, ...]]],
]:
    """Build Python ``re.IGNORECASE`` equivalence classes.

    CPython's regex engine uses its one-code-point lowercase mapping plus the
    small ``re._casefix`` closure (for example dotless i and long s).  Keeping
    that oracle here avoids substituting full string case-folding, whose
    one-to-many mappings have different regex semantics.
    """
    try:
        import _sre
        from re._casefix import _EXTRA_CASES
    except ImportError as error:
        raise SystemExit(
            "the active Python runtime does not expose the CPython regex "
            "case-fold tables required for Unicode table generation"
        ) from error

    parents: dict[int, int] = {}

    def find(value: int) -> int:
        parents.setdefault(value, value)
        while parents[value] != value:
            parents[value] = parents[parents[value]]
            value = parents[value]
        return value

    def union(left: int, right: int) -> None:
        left_root = find(left)
        right_root = find(right)
        if left_root != right_root:
            parents[max(left_root, right_root)] = min(left_root, right_root)

    for value in scalar_values():
        lowered = _sre.unicode_tolower(value)
        if lowered != value:
            union(value, lowered)
    for source, targets in _EXTRA_CASES.items():
        for target in targets:
            union(source, target)

    grouped: defaultdict[int, list[int]] = defaultdict(list)
    for value in parents:
        grouped[find(value)].append(value)
    classes = [
        (min(members), tuple(sorted(members)))
        for members in grouped.values()
        if len(members) > 1
    ]
    classes.sort()
    simple = sorted(
        (member, canonical - member)
        for canonical, members in classes
        for member in members
        if member != canonical
    )
    ranges, mappings = compress_simple_entries(simple)
    mapping_index = dict(mappings)
    for value in scalar_values():
        expected = find(value) if value in parents else value
        actual = mapped_value(value, ranges, mapping_index)
        if actual != (expected,):
            raise AssertionError(
                f"regex case-fold mismatch at U+{value:04X}: "
                f"{actual!r} != {(expected,)!r}"
            )
    return ranges, mappings, classes


def mapped_value(
    value: int,
    ranges: list[tuple[int, int, int, int]],
    mappings: dict[int, tuple[int, ...]],
) -> tuple[int, ...]:
    for first, last, step, delta in ranges:
        if first <= value <= last and (value - first) % step == 0:
            return (value + delta,)
    return mappings.get(value, (value,))


def verify_case_table(
    transform: Callable[[str], str],
    ranges: list[tuple[int, int, int, int]],
    mappings: list[tuple[int, tuple[int, ...]]],
) -> None:
    mapping_index = dict(mappings)
    for value in scalar_values():
        expected = tuple(ord(character) for character in transform(chr(value)))
        actual = mapped_value(value, ranges, mapping_index)
        if actual != expected:
            raise AssertionError(
                f"case-table mismatch at U+{value:04X}: {actual!r} != {expected!r}"
            )


def verify_property_table(
    predicate: Callable[[int], bool], ranges: list[tuple[int, int]]
) -> None:
    range_index = 0
    for value in scalar_values():
        while range_index < len(ranges) and ranges[range_index][1] < value:
            range_index += 1
        actual = (
            range_index < len(ranges)
            and ranges[range_index][0] <= value <= ranges[range_index][1]
        )
        expected = predicate(value)
        if actual != expected:
            raise AssertionError(
                f"property-table mismatch at U+{value:04X}: {actual!r} != {expected!r}"
            )


def emit_delta_ranges(
    name: str, ranges: list[tuple[int, int, int, int]]
) -> None:
    print(f"static constexpr UnicodeDeltaRange {name}[] = {{")
    for first, last, step, delta in ranges:
        print(f"    {{0x{first:x}U, 0x{last:x}U, {step}U, {delta}}},")
    print("};\n")


def emit_mappings(
    name: str, mappings: list[tuple[int, tuple[int, ...]]]
) -> None:
    print(f"static constexpr UnicodeMapping {name}[] = {{")
    for source, targets in mappings:
        padded = targets + (0,) * (3 - len(targets))
        rendered = ", ".join(f"0x{target:x}U" for target in padded)
        print(f"    {{0x{source:x}U, {{{rendered}}}, {len(targets)}U}},")
    print("};\n")


def emit_property_ranges(
    name: str,
    ranges: list[tuple[int, int]],
    *,
    trailing_blank: bool = True,
) -> None:
    print(f"static constexpr UnicodePropertyRange {name}[] = {{")
    for first, last in ranges:
        print(f"    {{0x{first:x}U, 0x{last:x}U}},")
    print("};")
    if trailing_blank:
        print()


def emit_regex_case_classes(
    name: str, classes: list[tuple[int, tuple[int, ...]]]
) -> None:
    print(f"static constexpr UnicodeRegexCaseClass {name}[] = {{")
    for canonical, members in classes:
        padded = members + (0,) * (4 - len(members))
        rendered = ", ".join(f"0x{member:x}U" for member in padded)
        print(
            f"    {{0x{canonical:x}U, {{{rendered}}}, {len(members)}U}},"
        )
    print("};\n")


def main() -> None:
    options = arguments()
    require_pinned_runtime(
        allow_version_change=options.allow_version_change,
    )
    upper_ranges, upper_mappings = case_entries(str.upper)
    lower_ranges, lower_mappings = case_entries(str.lower)
    regex_case_ranges, regex_case_mappings, regex_case_classes = (
        regex_case_entries()
    )
    maximum_regex_case_width = max(
        len(members) for _, members in regex_case_classes
    )
    if maximum_regex_case_width > 4:
        raise AssertionError(
            "UnicodeRegexCaseClass member storage is too narrow: "
            f"{maximum_regex_case_width}"
        )
    verify_case_table(str.upper, upper_ranges, upper_mappings)
    verify_case_table(str.lower, lower_ranges, lower_mappings)
    maximum_mapping_width = max(
        len(targets)
        for _, targets in upper_mappings + lower_mappings
    )
    if maximum_mapping_width > 3:
        raise AssertionError(
            f"UnicodeMapping target storage is too narrow: {maximum_mapping_width}"
        )

    alphabetic_predicate = lambda value: chr(value).isalpha()
    alphabetic = property_ranges(alphabetic_predicate)
    verify_property_table(alphabetic_predicate, alphabetic)
    digit_predicate = lambda value: chr(value).isdigit()
    digit = property_ranges(digit_predicate)
    verify_property_table(digit_predicate, digit)
    decimal_predicate = lambda value: chr(value).isdecimal()
    decimal = property_ranges(decimal_predicate)
    verify_property_table(decimal_predicate, decimal)
    punctuation_predicate = (
        lambda value: unicodedata.category(chr(value)).startswith("P")
    )
    punctuation = property_ranges(punctuation_predicate)
    verify_property_table(punctuation_predicate, punctuation)
    alphanumeric_predicate = lambda value: chr(value).isalnum()
    alphanumeric = property_ranges(alphanumeric_predicate)
    verify_property_table(alphanumeric_predicate, alphanumeric)
    cased_predicate = lambda value: (chr(value) + "Σ").lower().endswith("ς")
    cased = property_ranges(cased_predicate)
    cased_points = {
        value for first, last in cased for value in range(first, last + 1)
    }
    verify_property_table(cased_predicate, cased)
    case_ignorable_predicate = (
        lambda value: value not in cased_points
        and ("A" + chr(value) + "Σ").lower().endswith("ς")
    )
    case_ignorable = property_ranges(case_ignorable_predicate)
    verify_property_table(case_ignorable_predicate, case_ignorable)

    print("// Generated by scripts/generate_cpp_unicode_tables.py; do not edit.")
    print(
        "// Oracle: CPython "
        f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}, "
        f"Unicode {unicodedata.unidata_version}."
    )
    print(
        "// Every Unicode scalar value is covered; compressed case/property tables "
        "are verified."
    )
    print(f"// Maximum full case-mapping width: {maximum_mapping_width} code points.\n")
    emit_delta_ranges("unicode_upper_ranges", upper_ranges)
    emit_mappings("unicode_upper_mappings", upper_mappings)
    emit_delta_ranges("unicode_lower_ranges", lower_ranges)
    emit_mappings("unicode_lower_mappings", lower_mappings)
    emit_delta_ranges("unicode_regex_case_ranges", regex_case_ranges)
    emit_mappings("unicode_regex_case_mappings", regex_case_mappings)
    emit_regex_case_classes("unicode_regex_case_classes", regex_case_classes)
    emit_property_ranges("unicode_alphabetic_ranges", alphabetic)
    emit_property_ranges("unicode_digit_ranges", digit)
    emit_property_ranges("unicode_decimal_ranges", decimal)
    emit_property_ranges("unicode_punctuation_ranges", punctuation)
    emit_property_ranges("unicode_alphanumeric_ranges", alphanumeric)
    emit_property_ranges("unicode_cased_ranges", cased)
    emit_property_ranges(
        "unicode_case_ignorable_ranges", case_ignorable,
        trailing_blank=False,
    )


if __name__ == "__main__":
    main()
