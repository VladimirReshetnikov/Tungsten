#!/usr/bin/env python3
"""Differentially exercise native evaluator edges beyond the recorded tests.

The recorded-test gate proves compatibility for calls that the Python unittest
suite happens to make.  This companion gate generates dense, deterministic
cross-products around sequence boundaries, selector direction, inexact
rounding, structural positions, level traversal, ordering state machines,
collection callback contracts, and Unicode/string-pattern behavior.
"""

from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import dataclass
import itertools
import json
from pathlib import Path
import subprocess
from typing import Callable, Iterable

import tungsten.expression as runtime
from tungsten.expression_parser import parse_input_form


ENGINE_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_NATIVE_BINARY = ENGINE_ROOT / "build" / "cpp" / "tungsten-cpp"


@dataclass(frozen=True)
class Expected:
    success: bool
    full_form: str | None
    messages: tuple[str, ...]
    message_texts: tuple[str, ...]
    prints: tuple[str, ...]


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--native-binary",
        "--cpp-binary",
        dest="native_binary",
        type=Path,
        default=DEFAULT_NATIVE_BINARY,
    )
    parser.add_argument(
        "--cluster",
        action="append",
        choices=(
            "rounding", "take-drop", "list", "structural", "traversal",
            "collections", "combinator-state", "combinators", "distribution",
            "array-shape", "ordering", "strings",
        ),
        help="Run only this matrix; repeat to select multiple matrices.",
    )
    parser.add_argument("--max-mismatches", type=int, default=50)
    parser.add_argument("--require-perfect", action="store_true")
    return parser.parse_args()


def _unique(values: Iterable[str]) -> list[str]:
    return list(dict.fromkeys(values))


def rounding_cases() -> list[str]:
    numbers = [
        "-3", "-2", "-1", "0", "1", "2", "3", "-2.5", "-1.5",
        "-.2", ".2", "1.5", "2.5", "3.7",
    ]
    cases: list[str] = []
    for head in ("Floor", "Ceiling", "Round", "IntegerPart", "FractionalPart", "Abs", "Sign"):
        cases.extend(f"{head}[{value}]" for value in numbers)
    for head in ("Floor", "Ceiling", "Round"):
        cases.extend(
            f"{head}[{value},{unit}]"
            for value, unit in itertools.product(
                numbers, ("-2", "-1", "-.5", ".2", ".5", "1", "2")
            )
        )
    for head in ("Mod", "Quotient", "QuotientRemainder"):
        cases.extend(
            f"{head}[{left},{right}]"
            for left, right in itertools.product(
                numbers[:8], ("-3", "-2", "-1", "1", "2", "3")
            )
        )
    for head in ("RotateLeft", "RotateRight"):
        cases.extend(
            f"{head}[{{a,b,c}},{amount}]"
            for amount in (-10, -4, -3, -2, -1, 0, 1, 2, 3, 4, 10)
        )
    for head in ("Take", "Drop"):
        cases.extend(
            f"{head}[{{a,b,c}},{amount}]"
            for amount in (-5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5)
        )
    for head in ("RankedMin", "RankedMax"):
        cases.extend(
            f"{head}[{{3,1,2}},{rank}]"
            for rank in (-5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5)
        )
    for head in ("NumericalSort", "AlphabeticSort"):
        cases.extend(
            f"{head}[{values}]"
            for values in (
                '{"x02","x2","x10","x1"}',
                '{"A2","a10","a1"}',
                '{2,"x1",1}',
            )
        )
    cases.extend(
        (
            "Floor[1.*^100]",
            "Ceiling[-1.*^100]",
            "Round[1.*^100]",
            "IntegerPart[-1.*^100]",
            'NumericalSort[{"x9999999999999999999999999999999999999999999","x2","x10"}]',
            "RotateLeft[{a,b,c},999999999999999999999999999999999999999]",
            "RotateRight[{a,b,c},999999999999999999999999999999999999999]",
        )
    )
    return _unique(cases)


def take_drop_cases() -> list[str]:
    sequences = (
        "{a,b,c}",
        "f[a,b,c]",
        "{}",
        "Association[a->1,b->2,c->3]",
    )
    specifications: list[str] = [str(value) for value in range(-5, 6)]
    specifications.append("All")
    specifications.extend(f"{{{value}}}" for value in range(-5, 6))
    specifications.extend(
        f"{{{first},{last}}}"
        for first, last in itertools.product(range(-4, 5), repeat=2)
    )
    specifications.extend(
        f"{{{first},{last},{step}}}"
        for first, last, step in itertools.product(
            range(-3, 4), range(-3, 4), (-2, -1, 1, 2)
        )
    )
    specifications.extend(f"UpTo[{value}]" for value in range(-2, 6))
    return [
        f"{head}[{sequence},{specification}]"
        for head, sequence, specification in itertools.product(
            ("Take", "Drop"), sequences, specifications
        )
    ]


def list_cases() -> list[str]:
    sequences = ("{a,b,c}", "f[a,b,c]", "{}", "Association[a->1,b->2,c->3]")
    cases: list[str] = []
    for head in ("First", "Last"):
        for value in (*sequences, "a"):
            cases.extend((f"{head}[{value}]", f"{head}[{value},z]"))
    for head in ("Rest", "Most"):
        cases.extend(f"{head}[{value}]" for value in (*sequences, "a"))
    for head in ("Append", "Prepend"):
        cases.extend(
            f"{head}[{value},{item}]"
            for value, item in itertools.product(
                (*sequences, "a"), ("x", "Sequence[x,y]", "Nothing")
            )
        )
    cases.extend(
        f"Join[{left},{right}]"
        for left, right in itertools.product(sequences, repeat=2)
    )
    for value in sequences:
        cases.append(f"Reverse[{value}]")
        cases.extend(
            f"Reverse[{value},{specification}]"
            for specification in ("0", "1", "2", "All", "{1}", "{1,2}")
        )
    for value in sequences[:3]:
        for separator in ("x", "{x,y}", "Sequence[x,y]"):
            cases.extend(
                (
                    f"Riffle[{value},{separator}]",
                    f"Riffle[{value},{separator},{{1,-1,2}}]",
                )
            )
    for value in sequences[:3]:
        cases.extend(f"Partition[{value},{width}]" for width in range(-1, 6))
        cases.extend(
            f"Partition[{value},{width},{step}]"
            for width, step in itertools.product(range(0, 5), repeat=2)
        )
    for head in ("PadLeft", "PadRight"):
        for value in sequences[:3]:
            cases.extend(f"{head}[{value},{width}]" for width in range(-1, 7))
            cases.extend(
                f"{head}[{value},{width},{padding}]"
                for width, padding in itertools.product(range(0, 6), ("x", "{x,y}"))
            )
    cases.extend(("GatherBy[{1,2,3}]", "Permute[{},{}]"))
    return _unique(cases)


def structural_cases() -> list[str]:
    sequences = ("{a,b,c}", "f[a,b,c]", "{}", "Association[a->1,b->2,c->3]")
    positions = (
        "-5", "-4", "-3", "-2", "-1", "0", "1", "2", "3", "4", "5",
        "{1}", "{-1}", "{0}", "{{1},{3}}", "All", "Span[1,2]",
    )
    cases: list[str] = []
    for head in ("Part", "Extract"):
        cases.extend(
            f"{head}[{value},{position}]"
            for value, position in itertools.product(sequences, positions)
        )
    for head in ("Delete", "Insert"):
        for value, position in itertools.product(sequences, positions):
            cases.append(
                f"Delete[{value},{position}]"
                if head == "Delete"
                else f"Insert[{value},z,{position}]"
            )
    cases.extend(
        f"ReplacePart[{value},{position}->z]"
        for value, position in itertools.product(sequences, positions)
    )
    for value in sequences:
        for pattern in ("a", "_Symbol", "_Integer", "x_ /; x===b"):
            cases.extend(
                (
                    f"DeleteCases[{value},{pattern}]",
                    f"DeleteCases[{value},{pattern},{{0,Infinity}}]",
                    f"Replace[{value},{pattern}->z,{{0,Infinity}}]",
                )
            )
    return _unique(cases)


def traversal_cases() -> list[str]:
    expressions = (
        "a",
        "f[]",
        "f[a,g[b],h[c,d]]",
        "{a,g[b],h[c,d]}",
        "<||>",
        "<|a->x,b:>g[y],c->h[z,w]|>",
        "<|a-><|x->p|>,b->g[q]|>",
        "{a,Nothing,g[b,Nothing]}",
    )
    specifications = (
        "-5", "-3", "-2", "-1", "0", "1", "2", "3", "Infinity",
        "{-3}", "{-2}", "{-1}", "{0}", "{1}", "{2}", "{3}",
        "{0,Infinity}", "{1,2}", "{-3,-1}", "{2,Infinity}", "{1,-1}",
    )
    cases: list[str] = []
    for expression, specification in itertools.product(expressions, specifications):
        cases.append(f"Level[{expression},{specification}]")
        for head in ("Apply", "Map", "MapApply", "MapIndexed"):
            cases.append(f"{head}[q,{expression},{specification}]")

    for expression in expressions:
        cases.extend(
            (
                f"Apply[q,{expression}]",
                f"Map[q,{expression}]",
                f"Map[q,{expression},Heads->False]",
                f"Map[q,{expression},Heads->True]",
                f"Map[q,{expression},{{1,2}},Heads->True]",
                f"MapApply[q,{expression}]",
                f"MapApply[q][{expression}]",
                f"MapIndexed[q,{expression}]",
                f"MapIndexed[q][{expression}]",
            )
        )

    huge = "999999999999999999999999999999999999999"
    cases.extend(
        (
            f"Level[f[a,g[b]],{huge}]",
            f"Level[f[a,g[b]],{{-{huge}}}]",
            f"Apply[q,f[a,g[b]],{huge}]",
            f"Map[q,f[a,g[b]],{{-{huge}}}]",
            f"MapApply[q,f[a,g[b]],{huge}]",
            f"MapIndexed[q,f[a,g[b]],{{-{huge}}}]",
            "Map[Function[Nothing],{a,g[b]},Infinity]",
            "MapIndexed[Function[{value,path},path],<|a->x,b->g[y]|>,Infinity]",
            "Level[x,1,False]",
            "Level[x]",
            "Level[x,1,False,z]",
            "Level[x,1,z]",
            "Level[x,1,True]",
            "Level[x,z]",
            "Level[x,{z}]",
            "Level[x,{1,z}]",
            "Apply[q]",
            "Apply[q,x,1,z]",
            "Apply[q,x,z]",
            "Apply[q,x,{z}]",
            "Map[q]",
            "Map[q,x,1,z]",
            "Map[q,x,z]",
            "Map[q,x,{z}]",
            "MapApply[]",
            "MapApply[q]",
            "MapApply[q,x,1,z]",
            "MapApply[q,x,z]",
            "MapApply[q,x,{z}]",
            "MapIndexed[]",
            "MapIndexed[q]",
            "MapIndexed[q,x,1,z]",
            "MapIndexed[q,x,z]",
            "MapIndexed[q,x,{z}]",
        )
    )
    return _unique(cases)


def collections_cases() -> list[str]:
    cases: list[str] = []

    structural_pairs = (
        ("{}", "{}"),
        ("{1,2,3}", "{2,3}"),
        ("{1,2}", "{2,3}"),
        ("{1,1,2}", "{2,1,2}"),
        ("<|a->1,b->2,c->3|>", "<|x->2,y->3|>"),
        ("<||>", "<||>"),
    )
    for head in ("ContainsAll", "ContainsAny", "ContainsNone", "ContainsExactly"):
        cases.extend(f"{head}[{left},{right}]" for left, right in structural_pairs)
        cases.extend(
            (
                f"{head}[f[1],{{1}}]",
                f"{head}[Association[x],{{1}}]",
                f"{head}[{{1}}]",
                f"{head}[{{1}},{{1}},x]",
            )
        )
    cases.extend(
        (
            'ContainsAll[(Print["collection-arg"];f[1]),{1}]',
            "CountDistinct[{}]",
            "CountDistinct[{1,1.0,1,1.0}]",
            "CountDistinct[<|a->x,b->x,c->y|>]",
            "CountDistinct[f[a,a,b]]",
            "CountDistinct[Association[x]]",
            "CountDistinct[]",
            "CountDistinct[{1},x]",
            "CountDistinctBy[{1,2,3},Parity]",
        )
    )

    for head in ("AllTrue", "AnyTrue", "NoneTrue"):
        cases.extend(
            (
                f"{head}[{{}},IntegerQ]",
                f"{head}[{{1,2,3}},IntegerQ]",
                f"{head}[<|a->1,b->2|>,IntegerQ]",
                f"{head}[f[1,2],IntegerQ]",
                f"{head}[{{1}}]",
                f"{head}[{{1}},IntegerQ,x]",
            )
        )
    cases.extend(
        (
            "AllTrue[{1,2,3},(Print[#];#<2)&]",
            "AnyTrue[{1,2,3},(Print[#];#==2)&]",
            "NoneTrue[{1,2,3},(Print[#];#==2)&]",
            "Catch[AllTrue[{1,2,3},(Print[#];If[#==2,Throw[x]];True)&]]",
            "CheckAbort[AnyTrue[{1,2,3},(Print[#];If[#==2,Abort[]];False)&],caught]",
            "CheckAbort[AbortProtect[AllTrue[{1,2},"
            '(Print[#];If[#==1,Abort[]];True)&];Print["after"]],caught]',
        )
    )

    for head in ("Tally", "Counts"):
        cases.extend(
            (
                f"{head}[{{}}]",
                f"{head}[{{x,x,y}}]",
                f"{head}[<|a->x,b->x,c->y|>]",
                f"{head}[{{1,2,3}},#1<#2&]",
                f"{head}[{{1,2}},(Print[{{#1,#2}}];False)&]",
                f"Catch[{head}[{{1,2,3}},"
                "(Print[{#1,#2}];Throw[x])&]]",
                f"{head}[f[x,x,y]]",
                f"{head}[]",
                f"{head}[{{1}},SameQ,x]",
            )
        )

    cases.extend(
        (
            "CountsBy[{},Identity]",
            "CountsBy[{1.5,1.7,2.2},Floor]",
            "CountsBy[<|a->1.5,b->1.7,c->2.2|>,Floor]",
            "CountsBy[{1,2,3},(Print[#];Mod[#,2])&]",
            "Catch[CountsBy[{1,2,3},(Print[#];If[#==2,Throw[x]];#)&]]",
            'Enclose[CountsBy[{1,2,3},(Print[#];If[#==2,'
            'Confirm[Failure["stop",<||>]]];#)&]]',
            "CheckAbort[AbortProtect[Abort[];CountsBy[{1,2},"
            '(Print[#];#)&];Print["after"]],caught]',
            "CountsBy[f[1,2],Identity]",
            "CountsBy[Association[x],Identity]",
            "CountsBy[{1}]",
            "CountsBy[{1},Identity,x]",
        )
    )

    cases.extend(
        (
            "ContainsOnly[{1,2},{0,1,2,3}]",
            "ContainsOnly[{1,4},{0,1,2,3}]",
            "ContainsOnly[{},{}]",
            "ContainsOnly[{},f[]]",
            "ContainsOnly[<|a->1,b->2|>,<|x->1,y->2,z->3|>]",
            "ContainsOnly[{1.0,2.0},{0,1,2},SameTest->Equal]",
            "ContainsOnly[{1.0},{1},SameTest:>Equal]",
            "ContainsOnly[{1,2},{1,2},SameTest->Equal,SameTest->Automatic]",
            "ContainsOnly[{1.0},{1},SameTest->SameQ,SameTest->Equal]",
            'ContainsOnly[{1.0,2.0},{0,1,2},SameTest:>'
            '(Print["delayed"];Equal)]',
            "Catch[ContainsOnly[{1,2},{0,1,2},"
            "SameTest->((Print[{#1,#2}];Throw[x])&)]]",
            "ContainsOnly[f[1],g[1]]",
            "ContainsOnly[Association[x],{1}]",
            "ContainsOnly[{1},{1},Heads->False]",
            "ContainsOnly[{1},{1},WorkingPrecision->20]",
            "ContainsOnly[{1},{1},Rule[SameTest]]",
            "ContainsOnly[{1},{1},1->Equal]",
            "ContainsOnly[{1},SameTest->Equal,{1}]",
            "ContainsOnly[{1}]",
        )
    )

    cases.extend(
        (
            "Accumulate[{}]",
            "Accumulate[{1,2,3,4}]",
            "Accumulate[{1,2,3,4},Times]",
            "Accumulate[System`List[1,2,3]]",
            "Accumulate[<||>]",
            "Accumulate[<|a->1,b->2,c->3|>]",
            "Accumulate[Association[RuleDelayed[a,1],RuleDelayed[b,2]]]",
            "Accumulate[System`Association[System`RuleDelayed[a,1],"
            "System`Rule[b,2]]]",
            "Catch[Accumulate[{1,2,3},(Print[{#1,#2}];"
            "If[#2==2,Throw[x]];Plus[#1,#2])&]]",
            "CheckAbort[Accumulate[{1,2,3},(Print[{#1,#2}];"
            "If[#2==2,Abort[]];Plus[#1,#2])&],caught]",
            "CheckAbort[AbortProtect[Abort[];Accumulate[{1,2,3},"
            '(Print[{#1,#2}];Plus[#1,#2])&];Print["after"]],caught]',
            "Accumulate[f[1,2]]",
            "Accumulate[Association[x]]",
            "Accumulate[]",
            "Accumulate[{1},Plus,x]",
        )
    )
    return _unique(cases)


def array_shape_cases() -> list[str]:
    """Dense, sparse, ragged, and diagnostic shape contracts."""

    cases = [
        "Dimensions[5]",
        "Dimensions[f[a,b]]",
        "Dimensions[Association[a->1,b->2]]",
        "Dimensions[{}]",
        "Dimensions[{{}}]",
        "Dimensions[{{1,2},{3,4}}]",
        "Dimensions[{{1,2},{3}}]",
        "Dimensions[{{{1}},{{2,3}}}]",
        "Dimensions[{SparseArray[{}, {2,3}],SparseArray[{}, {2,3}]}]",
        "Dimensions[]",
        "Dimensions[{},{}]",
        "ArrayDepth[5]",
        "ArrayDepth[f[a,b]]",
        "ArrayDepth[Association[a->1,b->2]]",
        "ArrayDepth[{}]",
        "ArrayDepth[{{1},{2,3,4}}]",
        "ArrayDepth[{{{1}},2}]",
        "ArrayDepth[{SparseArray[{}, {2,3}]}]",
        "ArrayDepth[]",
        "ArrayDepth[{},{}]",
        "ArrayQ[5]",
        "ArrayQ[f[a,b]]",
        "ArrayQ[Association[a->1]]",
        "ArrayQ[{}]",
        "ArrayQ[{{}}]",
        "ArrayQ[{{1,2},{3,4}}]",
        "ArrayQ[{{1},{2,3}}]",
        "ArrayQ[{{1}},2,IntegerQ]",
        "ArrayQ[{{1}},1,IntegerQ]",
        "ArrayQ[{{1}},-1]",
        "ArrayQ[{{1}},foo]",
        "ArrayQ[5,foo]",
        "ArrayQ[{{1},{2,3}},foo]",
        "ArrayQ[]",
        "ArrayQ[{},1,Identity,x]",
        "VectorQ[5]",
        "VectorQ[f[a,b]]",
        "VectorQ[Association[a->1]]",
        "VectorQ[{}]",
        "VectorQ[{f[a]}]",
        "VectorQ[{1,{2}}]",
        "VectorQ[{1,2,3},IntegerQ]",
        "VectorQ[]",
        "VectorQ[{1},IntegerQ,x]",
        "MatrixQ[5]",
        "MatrixQ[f[a,b]]",
        "MatrixQ[Association[a->1]]",
        "MatrixQ[{}]",
        "MatrixQ[{{}}]",
        "MatrixQ[{{1,2},{3,4}}]",
        "MatrixQ[{{1,2},{3}}]",
        "MatrixQ[{{1,2},{3,4}},IntegerQ]",
        "MatrixQ[]",
        "MatrixQ[{{1}},IntegerQ,x]",
        "Dimensions[SparseArray[{}, {4294967296}]]",
        "Dimensions[SparseArray[{}, {4294967296,4294967296}]]",
        "Dimensions[SparseArray[{}, {0,1000000000}]]",
        "ArrayDepth[SparseArray[{}, {4294967296,4294967296}]]",
        "ArrayDepth[SparseArray[{}, {0,1000000000}]]",
        "ArrayQ[SparseArray[{}, {4294967296}],1]",
        "ArrayQ[SparseArray[{}, {4294967296}],2]",
        "ArrayQ[SparseArray[{}, {4294967296}],1,OddQ]",
        "ArrayQ[SparseArray[{}, {0,1000000000}],2,OddQ]",
        "VectorQ[SparseArray[{}, {4294967296}],OddQ]",
        "VectorQ[SparseArray[{}, {0}],OddQ]",
        "MatrixQ[SparseArray[{}, {4294967296,4294967296}],OddQ]",
        "MatrixQ[SparseArray[{}, {0,1000000000}],OddQ]",
        "SparseArray[{}, {4294967296,4294967296}][\"Density\"]",
        (
            "SparseArray[{{1,1}->1},{4294967296,4294967296}]"
            "[\"Density\"]"
        ),
        (
            "ArrayQ[{{1,2},{3,4}},2,Function[x,"
            "Print[InputForm[x]];IntegerQ[x]]]"
        ),
        (
            "ArrayQ[SparseArray[{{2}->a},{3}],1,Function[x,"
            "Print[InputForm[x]];True]]"
        ),
        (
            "VectorQ[{1,2,3},Function[x,"
            "Print[InputForm[x]];IntegerQ[x]]]"
        ),
        (
            "MatrixQ[{{1,2},{3,4}},Function[x,"
            "Print[InputForm[x]];IntegerQ[x]]]"
        ),
        (
            "MatrixQ[SparseArray[{{2,2}->a},{2,2}],Function[x,"
            "Print[InputForm[x]];True]]"
        ),
        (
            "Catch[ArrayQ[{{1,2},{3,4}},2,Function[x,"
            "Print[InputForm[x]];If[SameQ[x,2],Throw[stop]];True]]]"
        ),
        (
            "CheckAbort[VectorQ[{1,2,3},Function[x,"
            "Print[InputForm[x]];If[SameQ[x,2],Abort[]];True]],caught]"
        ),
        (
            "MatrixQ[SparseArray[{{2,2}->a},{2,2}],Function[x,"
            "Print[InputForm[x]];False]]"
        ),
        (
            "ArrayQ[SparseArray[{}, {0,1000000000}],2,Function[x,"
            "Print[\"unexpected\"];False]]"
        ),
    ]
    return _unique(cases)


def string_cases() -> list[str]:
    strings = ('""', '"a"', '"ab"', '"aba"', '"a b"', '"café λ"')
    patterns = (
        '"a"', '""', 'Alternatives["a","b"]', 'Repeated["a"]',
        "DigitCharacter", "LetterCharacter", "__",
    )
    cases: list[str] = []
    for head in (
        "StringLength", "Characters", "StringReverse", "ToUpperCase", "ToLowerCase",
        "LetterQ", "DigitQ",
    ):
        cases.extend(f"{head}[{value}]" for value in strings)
    cases.extend(
        f"CharacterRange[{left},{right}]"
        for left, right in itertools.product(('"a"', '"c"', '"A"', '"1"'), repeat=2)
    )
    for head in (
        "StringContainsQ", "StringFreeQ", "StringStartsQ", "StringEndsQ",
        "StringMatchQ", "StringPosition", "StringCases",
    ):
        for value, pattern in itertools.product(strings, patterns):
            cases.append(f"{head}[{value},{pattern}]")
            if head in ("StringPosition", "StringCases"):
                cases.append(f"{head}[{value},{pattern},2]")
    for value, pattern, replacement in itertools.product(
        strings, patterns[:4], ('"x"', 'f["x"]')
    ):
        cases.extend(
            (
                f"StringReplace[{value},{pattern}->{replacement}]",
                f"StringReplace[{value},{pattern}->{replacement},2]",
            )
        )
    for value in strings:
        cases.extend(
            f"StringSplit[{value},{separator}]"
            for separator in ("Whitespace", '"a"', '""')
        )
        for position in ("1", "-1", "0", "{1}", "{1,2}", "{{1},{-1}}"):
            cases.extend(
                (
                    f"StringTake[{value},{position}]",
                    f"StringDrop[{value},{position}]",
                )
            )
    cases.extend(
        (
            'StringJoin["a","b"]',
            'StringJoin["","a"]',
            'StringJoin["café","λ"]',
        )
    )
    return _unique(cases)


def combinator_state_cases() -> list[str]:
    """State-machine boundaries whose parity includes messages and prints."""

    return [
        (
            "Catch[Fold[Function[{acc,x},Print[InputForm[x]];"
            "If[SameQ[x,b],Throw[boom]];p[acc,x]],z,{a,b,c}]]"
        ),
        (
            "CheckAbort[FoldList[Function[{acc,x},Print[InputForm[x]];"
            "If[SameQ[x,b],Abort[]];p[acc,x]],z,{a,b,c}],caught]"
        ),
        (
            "worker[]:=SequenceFoldList[Function[Null,Print[InputForm[#3]];"
            "If[SameQ[#3,b],Return[returned]];q[##]],{x0,x1},{a,b,c}];worker[]"
        ),
        (
            "Catch[FoldWhileList[Function[{acc,x},Print[InputForm[x]];"
            "If[SameQ[x,b],Throw[boom]];p[acc,x]],z,{a,b,c},Function[x,True]]]"
        ),
        (
            "Catch[ComposeList[{Function[x,Print[InputForm[x]];f[x]],"
            "Function[x,Print[InputForm[x]];Throw[boom]],"
            "Function[x,Print[InputForm[x]];h[x]]},z]]"
        ),
        (
            "Catch[Comap[{Function[x,Print[\"a\"];f[x]],"
            "Function[x,Print[\"b\"];Throw[boom]],"
            "Function[x,Print[\"c\"];h[x]]},z]]"
        ),
        (
            "Catch[Discard[{a,b,c},Function[x,Print[InputForm[x]];"
            "If[SameQ[x,b],Throw[boom]];False]]]"
        ),
        "Discard[{a,b,c},Function[x,Print[InputForm[x]];True],1]",
        (
            "CheckAbort[AbortProtect[Fold[Function[{acc,x},Abort[];"
            "Print[InputForm[x]];p[acc,x]],z,{a,b,c}]],caught]"
        ),
        "FoldWhileList[Plus,0,{1,2,3,4},Function[x,Less[x,4]]]",
        "FoldWhile[Plus,0,{1,2,3,4},Function[x,Less[x,4]]]",
        (
            "FoldWhileList[Function[{a,x},Plus[a,x]],0,{1,2,3},"
            "Function[Null,Print[InputForm[{##}]];True],2]"
        ),
        (
            "FoldWhileList[Function[{a,x},Plus[a,x]],0,{1,2},"
            "Function[Null,Print[InputForm[{##}]];True],All]"
        ),
        "FoldWhileList[Plus,0,{1,2,3,4,5},Function[x,Less[x,4]],1,2]",
        "FoldWhileList[Plus,0,{1,2,3,4},Function[x,Less[x,4]],1,-20]",
        "FoldWhileList[f,z,{},Function[x,Print[\"predicate\"];False]]",
        "FoldWhileList[f,z,g[a,b],Function[x,True]]",
        "FoldWhileList[f,z,<|a->x,b:>y|>,Function[x,True]]",
        "FoldWhileList[f,z,{a}]",
        "foldWhileAtomic=1;FoldWhile[f,z,foldWhileAtomic,p]",
        "FoldWhileList[f,z,{a},p,0]",
        "FoldWhileList[Plus,0,{1},Function[x,Less[x,1]],1,foo]",
        "FoldWhileList[Plus,0,{1},Function[x,True],1,foo]",
        "SequenceFoldList[f,{x0,x1},{a,b,c}]",
        "SequenceFold[f,{x0,x1},{a,b,c,d},4]",
        "SequenceFoldList[f,{x0,x1},{a,b,c,d,e},4]",
        "SequenceFoldList[f,g[x0,x1],h[a,b]]",
        "SequenceFoldList[f,<|a->x0,b:>x1|>,<|p->a,q:>b|>]",
        "SequenceFoldList[f,{s},SparseArray[{{2}->x},{3},z]]",
        "SequenceFoldList[f,{s},SparseArray[{}, {2,2}, z]]",
        "SequenceFoldList[f,{},{}]",
        "SequenceFoldList[f,{},x]",
        "SequenceFoldList[f,{x0,x1},{a},1]",
        "SequenceFoldList[f,{x0,x1},{a},2]",
        "SequenceFoldList[f,{x0},{a},foo]",
        (
            "FoldPairList[Function[{st,item},{emit[st,item],state[st,item]}],"
            "z,{a,b,c}]"
        ),
        "FoldPair[Function[{s,x},{emit[s,x],state[s,x]}],z,g[a,b]]",
        (
            "FoldPairList[Function[{st,item},{emit[st,item],state[st,item]}],"
            "z,<|a->x,b:>y|>]"
        ),
        (
            "FoldPairList[Function[{s,x},{emit[s,x],state[s,x]}],"
            "z,{a,b},Function[p,h[p]]]"
        ),
        "FoldPairList[f,z,g[]]",
        "FoldPair[f,z,g[]]",
        "FoldPairList[Function[{s,x},bad[s,x]],z,{a}]",
        "FoldPair[Function[{s,x},{a,b,c}],z,{a}]",
        "FoldPairList[f,z,x]",
        "FoldPair[f,z,{a},p,q]",
        (
            "Catch[FoldPairList[Function[{s,x},{emit[s,x],state[s,x]}],"
            "z,{a,b},Function[p,Print[InputForm[p]];"
            "If[SameQ[First[p],emit[z,a]],Throw[boom]];p]]]"
        ),
    ]


def combinator_cases() -> list[str]:
    """Higher-order container, projection, and head-chain contracts."""

    return [
        "Discard[g[a,b,c,d],Function[x,UnsameQ[x,b]],2]",
        "Discard[<|x->a,y:>b,z->c|>,Function[v,SameQ[v,b]]]",
        "Discard[g[a,b,c],Function[x,SameQ[x,b]]->\"Element\"]",
        "Discard[g[a,b,c],Function[x,SameQ[x,b]]->\"Index\"]",
        (
            "Discard[g[a,b,c],Function[x,SameQ[x,b]]->"
            "{\"Element\",\"Index\"}]"
        ),
        "Discard[g[a,b],Function[x,True]->{}]",
        "Discard[{a,b,c},Function[x,Print[InputForm[x]];True],0]",
        "Discard[{a,b,c},Function[x,SameQ[x,b]],Infinity]",
        "Discard[{a,b},p,-1]",
        "Discard[x,p]",
        "Discard[{a},p->\"Unknown\"]",
        "Discard[{a},Rule[p],1]",
        "Discard[{a},p,1,extra]",
        "Discard[Function[x,SameQ[x,b]]][g[a,b,c]]",
        "Discard[Function[x,SameQ[x,b]]]",
        (
            "Catch[Discard[{a,b,c},Function[x,Print[InputForm[x]];"
            "If[SameQ[x,b],Throw[boom]];False]]]"
        ),
        (
            "CheckAbort[AbortProtect[Discard[{a,b},Function[x,Abort[];"
            "Print[InputForm[x]];False]]],caught]"
        ),
        "ComposeList[{},z]",
        "ComposeList[g[a,b],z]",
        "ComposeList[<|a->f,b:>g|>,z]",
        "ComposeList[x,z]",
        "ComposeList[f]",
        (
            "Catch[ComposeList[g[Function[x,Print[\"a\"];f[x]],"
            "Function[x,Print[\"b\"];Throw[boom]],"
            "Function[x,Print[\"c\"];h[x]]],z]]"
        ),
        "Comap[g[f,h],x]",
        "Comap[<|a->f,b:>g|>,x]",
        "Comap[q,x]",
        "Comap[g[f,h]][x]",
        "Comap[g[f,h],x,extra]",
        (
            "Catch[Comap[g[Function[x,Print[\"a\"];f[x]],"
            "Function[x,Print[\"b\"];Throw[boom]],"
            "Function[x,Print[\"c\"];h[x]]],z]]"
        ),
        "ComapApply[g[f,h],p[a,b]]",
        "ComapApply[<|a->f,b:>g|>,p[a,b]]",
        "ComapApply[g[f,h],<|a->x,b:>y|>]",
        "ComapApply[g[f,h],x]",
        "ComapApply[q,p[a,b]]",
        "ComapApply[g[f,h]][p[a,b]]",
        "ComapApply[g[f,h],p[a,b],extra]",
        (
            "Catch[ComapApply[g[Function[Null,Print[\"a\"];f[##]],"
            "Function[Null,Print[\"b\"];Throw[boom]],"
            "Function[Null,Print[\"c\"];h[##]]],p[x,y]]]"
        ),
        "Operate[p,x,0]",
        "Operate[p,f[g][x]]",
        "Operate[p,f[g][x],2]",
        "Operate[p,f[g][x],3]",
        "Operate[p,f[g][x],1000000000000000000000000000000]",
        "Operate[p,f[x],-1]",
        "Operate[p,f[x],n]",
        "Operate[p]",
        (
            "Catch[Operate[Function[x,Print[InputForm[x]];Throw[boom]],"
            "f[g][z],2]]"
        ),
        "LengthWhile[g[1,2,0],Function[x,Greater[x,0]]]",
        "LengthWhile[<|a->1,b:>2,c->0|>,Function[x,Greater[x,0]]]",
        "LengthWhile[x,p]",
        "LengthWhile[{a},p,extra]",
        (
            "Catch[LengthWhile[g[a,b,c],Function[x,Print[InputForm[x]];"
            "If[SameQ[x,b],Throw[boom]];True]]]"
        ),
        (
            "CheckAbort[AbortProtect[LengthWhile[g[a,b],Function[x,Abort[];"
            "Print[InputForm[x]];True]]],caught]"
        ),
    ]


def distribution_cases() -> list[str]:
    """Threading and Cartesian distribution without result re-evaluation."""

    return [
        "Thread[f[{a,b},x,{c,d}]]",
        "Thread[f[g[a,b],x,g[c,d]],g]",
        "Thread[f[g[],x],g]",
        "Thread[f[g[a,b],x,h[c,d]],g]",
        "Thread[f[x,y]]",
        "Thread[x]",
        "Thread[f[{a},{b,c}]]",
        "Thread[]",
        "Thread[f[x],List,extra]",
        "Thread[<|a->{x,y},b->z|>]",
        "Thread[f[(h[q])[a,b],x,(h[q])[c,d]],h[q]]",
        "Distribute[Times[Plus[a,b],Plus[c,d]]]",
        "Distribute[f[g[a,b],x,g[c,d]],g]",
        "Distribute[f[g[a,b],x],g,f]",
        "Distribute[q[g[a,b],x],g,f]",
        "Distribute[f[g[a,b],g[c,d]],g,f,h,k]",
        "Distribute[q[g[a,b]],g,f,h,k]",
        "Distribute[x]",
        "Distribute[f[a,b],g]",
        "Distribute[f[g[],x],g]",
        "Distribute[f[],g]",
        "Distribute[]",
        "Distribute[f[g[a,b]],g,f,h]",
        "Distribute[f[(h[q])[a,b],x],h[q]]",
        (
            "ClearAll[f];SetAttributes[f,Orderless];"
            "Distribute[f[g[a,b],g[b,a]],g]"
        ),
        "Distribute[<|a->g[x,y]|>,g]",
    ]


def ordering_cases() -> list[str]:
    """Canonical-order boundaries and observable ordering callbacks."""

    larger = "1" + "0" * 400
    smaller = "9" + "0" * 399
    return [
        f"Order[{larger},{smaller}]",
        f"Sort[{{{larger},{smaller}}}]",
        f"ReverseSort[{{{larger},{smaller}}}]",
        f"Ordering[{{{larger},{smaller}}}]",
        "Order[Complex[10,2],Complex[9,3]]",
        "Sort[{Complex[10,2],Complex[9,3]}]",
        "Sort[<|z->1,a->2|>]",
        "ReverseSort[<|z->1,a->2|>]",
        "Ordering[<|z->1,a->2|>]",
        "Order[]",
        "Order[a]",
        "Order[a,b,c]",
    ]


CLUSTERS: dict[str, Callable[[], list[str]]] = {
    "rounding": rounding_cases,
    "take-drop": take_drop_cases,
    "list": list_cases,
    "structural": structural_cases,
    "traversal": traversal_cases,
    "collections": collections_cases,
    "combinator-state": combinator_state_cases,
    "combinators": combinator_cases,
    "distribution": distribution_cases,
    "array-shape": array_shape_cases,
    "ordering": ordering_cases,
    "strings": string_cases,
}


def _clear_visible_effects() -> None:
    runtime._GLOBAL_MESSAGES.clear()
    runtime._GLOBAL_VISIBLE_MESSAGES.clear()
    runtime._GLOBAL_PRINTS.clear()


def _expected(source: str) -> Expected:
    _clear_visible_effects()
    try:
        result = runtime.evaluate(parse_input_form(source))
        success = True
        full_form = result.to_full_form()
    except Exception:
        success = False
        full_form = None
    return Expected(
        success=success,
        full_form=full_form,
        messages=tuple(
            message.name.to_full_form() for message in runtime._GLOBAL_VISIBLE_MESSAGES
        ),
        message_texts=tuple(
            message.text for message in runtime._GLOBAL_VISIBLE_MESSAGES
        ),
        prints=tuple(runtime._GLOBAL_PRINTS),
    )


def _native(binary: Path, sources: list[str]) -> list[dict[str, object]]:
    completed = subprocess.run(
        [str(binary), "eval-batch"],
        input="".join(json.dumps(source) + "\n" for source in sources),
        text=True,
        capture_output=True,
        check=False,
        timeout=120,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"native batch exited {completed.returncode}: "
            f"{completed.stderr.strip() or '<no stderr>'}"
        )
    payloads = [json.loads(line) for line in completed.stdout.splitlines()]
    if len(payloads) != len(sources):
        raise RuntimeError(
            f"native evaluator returned {len(payloads)} results for {len(sources)} cases"
        )
    return payloads


def _matches(expected: Expected, actual: dict[str, object]) -> bool:
    if bool(actual.get("success")) != expected.success:
        return False
    if expected.success and actual.get("full_form") != expected.full_form:
        return False
    return (
        tuple(actual.get("messages", [])) == expected.messages
        and tuple(actual.get("message_texts", [])) == expected.message_texts
        and tuple(actual.get("prints", [])) == expected.prints
    )


def main() -> int:
    arguments = _arguments()
    selected = arguments.cluster or list(CLUSTERS)
    binary = arguments.native_binary.resolve()
    if not binary.is_file():
        raise RuntimeError(f"native binary does not exist: {binary}")

    cases: list[tuple[str, str]] = []
    for cluster in selected:
        cases.extend((cluster, source) for source in CLUSTERS[cluster]())
    expectations = [_expected(source) for _cluster, source in cases]
    payloads = _native(binary, [source for _cluster, source in cases])

    mismatches: list[str] = []
    mismatch_clusters: Counter[str] = Counter()
    for (cluster, source), expected, actual in zip(
        cases, expectations, payloads, strict=True
    ):
        if _matches(expected, actual):
            continue
        mismatch_clusters[cluster] += 1
        expected_value = expected.full_form if expected.success else "<failure>"
        actual_value = actual.get("full_form") if actual.get("success") else "<failure>"
        mismatches.append(
            f"[{cluster}] {source}\n"
            f"  Python: {expected_value}; messages={expected.messages!r}; "
            f"texts={expected.message_texts!r}; prints={expected.prints!r}\n"
            f"  C++:    {actual_value}; messages={actual.get('messages', [])!r}; "
            f"texts={actual.get('message_texts', [])!r}; prints={actual.get('prints', [])!r}"
        )

    print(
        f"Matched {len(cases) - len(mismatches)}/{len(cases)} generated edge cases; "
        f"{len(mismatches)} mismatches."
    )
    for cluster in selected:
        count = sum(1 for case_cluster, _source in cases if case_cluster == cluster)
        failures = mismatch_clusters[cluster]
        print(f"  {cluster}: {count - failures}/{count}")
    if mismatches and arguments.max_mismatches != 0:
        shown = mismatches[: arguments.max_mismatches]
        print("\n\n".join(shown))
        if len(shown) < len(mismatches):
            print(f"\n... {len(mismatches) - len(shown)} additional mismatches omitted")
    return int(arguments.require_perfect and bool(mismatches))


if __name__ == "__main__":
    raise SystemExit(main())
