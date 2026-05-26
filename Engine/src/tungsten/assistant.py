from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path

from .kernel import KernelEvaluationResult, WolframKernelRunner
from .notebook import NotebookDocument, parse_wl_string_literal, wl_string


_ASSISTANT_HELPER_TEMPLATE = """
ClearAll[
    __CLEAR_NAMES__
];

tungstenError[type_String, message_String, extra_: <||>] :=
    Join[<|"success" -> False, "error_type" -> type, "error" -> message|>, extra];

tungstenStringValue[value_] := Replace[
    value,
    {
        None | Null | Inherited | Missing[__] -> Null,
        s_String :> s,
        other_ :> ToString[Unevaluated[other], InputForm, PageWidth -> Infinity]
    }
];

tungstenStringList[value_] := Replace[
    value,
    {
        s_String :> {s},
        list_List :> Cases[list, tag_String :> tag, Infinity],
        _ :> {}
    }
];

tungstenCompactText[text_String] := StringTake[
    StringTrim @ StringReplace[text, WhitespaceCharacter .. -> " "],
    UpTo[240]
];

tungstenCellMetadata[cell_CellObject] := Module[
    {cellExpr, preview},
    cellExpr = Quiet @ Check[NotebookRead @ cell, $Failed];
    preview = Quiet @ Check[__PREVIEW_EXPRESSION__, ""];
    <|
        "expression_uuid" -> tungstenStringValue @ CurrentValue[cell, ExpressionUUID],
        "cell_id" -> Replace[CurrentValue[cell, CellID], {value_Integer :> value, _ :> Null}],
        "cell_tags" -> tungstenStringList @ CurrentValue[cell, CellTags],
        "style" -> tungstenStringValue @ CurrentValue[cell, CellStyle],
        "preview" -> tungstenCompactText @ Replace[preview, Except[_String] :> ""]
    |>
];

tungstenFindNotebook[path_String] :=
    SelectFirst[Notebooks[], Quiet @ Check[NotebookFileName[#] === path, False] &, Missing["NotFound"]];

tungstenResolveNotebook[path_String] := Module[
    {existing, opened},
    existing = tungstenFindNotebook @ path;
    If[MatchQ[existing, _NotebookObject], Return[existing]];
    opened = Quiet @ Check[NotebookOpen[path], $Failed];
    If[
        MatchQ[opened, _NotebookObject],
        opened,
        tungstenError["NotebookOpenFailed", "Unable to open the requested notebook.", <|"notebook_path" -> path|>]
    ]
];

tungstenResolveCell[nbo_NotebookObject, selector_Association] := Module[
    {matches = {}, cellIndex, allCells},
    Which[
        StringQ @ Lookup[selector, "expression_uuid", Missing["NotFound"]],
            matches = Cells[nbo, ExpressionUUID -> selector["expression_uuid"]],
        IntegerQ @ Lookup[selector, "cell_id", Missing["NotFound"]],
            matches = Cells[nbo, CellID -> selector["cell_id"]],
        StringQ @ Lookup[selector, "cell_tag", Missing["NotFound"]],
            matches = Cells[nbo, CellTags -> selector["cell_tag"]],
        IntegerQ @ Lookup[selector, "cell_index", Missing["NotFound"]],
            allCells = Cells[nbo];
            cellIndex = selector["cell_index"] + 1;
            matches = If[1 <= cellIndex <= Length[allCells], {allCells[[cellIndex]]}, {}],
        True,
            matches = {}
    ];

    Which[
        Length[matches] == 1, First[matches],
        Length[matches] == 0,
            tungstenError["CellNotFound", "No notebook cell matched the requested selector.", <|"selector" -> selector|>],
        True,
            tungstenError[
                "AmbiguousCellSelector",
                "More than one notebook cell matched the requested selector.",
                <|"selector" -> selector, "match_count" -> Length[matches]|>
            ]
    ]
];
""".strip()


def _assistant_helper_block(
    *,
    preview_expression: str,
    extra_clear_names: tuple[str, ...] = (),
) -> str:
    clear_names = tuple(
        dict.fromkeys(
            (
                "tungstenError",
                "tungstenStringValue",
                "tungstenStringList",
                "tungstenCompactText",
                "tungstenCellMetadata",
                "tungstenFindNotebook",
                "tungstenResolveNotebook",
                "tungstenResolveCell",
                *extra_clear_names,
            )
        )
    )
    return (
        _ASSISTANT_HELPER_TEMPLATE
        .replace("__CLEAR_NAMES__", ",\n    ".join(clear_names))
        .replace("__PREVIEW_EXPRESSION__", preview_expression)
    )


@dataclass(frozen=True)
class NotebookAssistantResult:
    evaluation: KernelEvaluationResult
    payload: dict[str, object]

    @property
    def assistant_success(self) -> bool:
        return bool(self.payload.get("success"))

    def to_dict(self) -> dict[str, object]:
        return {
            "assistant_success": self.assistant_success,
            "assistant": self.payload,
            "evaluation": self.evaluation.to_dict(),
        }


class NotebookAssistantController:
    def __init__(self, runner: WolframKernelRunner | None = None) -> None:
        self.runner = runner or WolframKernelRunner()

    def ask_cell(
        self,
        *,
        notebook_path: Path,
        question: str,
        cell_index: int | None = None,
        cell_path: list[int] | None = None,
        expression_uuid: str | None = None,
        cell_id: int | None = None,
        cell_tag: str | None = None,
        insert_wolfram_code: bool = False,
        insert_all_wolfram_code: bool = False,
        save_notebook: bool = False,
        close_assistant_notebook: bool = False,
        extra_instructions: str | None = None,
        model_service: str | None = None,
        model_name: str | None = None,
    ) -> NotebookAssistantResult:
        source_row = self._resolve_row(
            notebook_path=notebook_path,
            cell_index=cell_index,
            cell_path=cell_path,
            expression_uuid=expression_uuid,
            cell_id=cell_id,
            cell_tag=cell_tag,
        )
        selector = self._resolve_selector(
            notebook_path=notebook_path,
            cell_index=cell_index,
            cell_path=cell_path,
            expression_uuid=expression_uuid,
            cell_id=cell_id,
            cell_tag=cell_tag,
        )

        insert_mode = "none"
        if insert_all_wolfram_code:
            insert_mode = "all"
        elif insert_wolfram_code:
            insert_mode = "first"

        evaluation = self.runner.evaluate_text(
            self._build_script(
                notebook_path=notebook_path.resolve(),
                question=question,
                selector=selector,
                insert_mode=insert_mode,
                save_notebook=save_notebook,
                close_assistant_notebook=close_assistant_notebook,
                extra_instructions=extra_instructions,
                model_service=model_service,
                model_name=model_name,
            ),
            require_front_end=True,
        )

        payload = self._parse_payload(evaluation)
        payload = self._finalize_ask_cell_payload(
            payload=payload,
            notebook_path=notebook_path,
            source_row=source_row,
            insert_mode=insert_mode,
            save_notebook=save_notebook,
        )
        return NotebookAssistantResult(evaluation=evaluation, payload=payload)

    def ask(
        self,
        *,
        prompt: str,
        system_prompt: str | None = None,
        extra_instructions: str | None = None,
        model_service: str | None = None,
        model_name: str | None = None,
        tools: list[str] | None = None,
    ) -> NotebookAssistantResult:
        """Send a free-form prompt to the Wolfram Notebook Assistant.

        Unlike `ask_cell`, this entry point does not require a notebook
        file or a cell selector. Tungsten still uses the same
        Wolfram`Chatbook` machinery under the hood (a temporary hidden
        chat notebook that the Notebook Assistant evaluates against and
        Tungsten throws away afterwards), but the caller only has to
        supply the prompt text.

        Returns a NotebookAssistantResult whose payload includes
        `response_text` (the assistant's text answer extracted from the
        chat object) and `code_blocks` / `wolfram_code_blocks` for any
        fenced code blocks the answer contained. Errors land in the
        same `success / error_type / error` shape used by the rest of
        the controller.
        """
        evaluation = self.runner.evaluate_text(
            self._build_ask_script(
                prompt=prompt,
                system_prompt=system_prompt,
                extra_instructions=extra_instructions,
                model_service=model_service,
                model_name=model_name,
                tools=tools,
            ),
            require_front_end=True,
        )

        payload = self._parse_payload(evaluation)
        payload = self._finalize_ask_payload(payload=payload)
        return NotebookAssistantResult(evaluation=evaluation, payload=payload)

    def prepare_inline(
        self,
        *,
        notebook_path: Path,
        cell_index: int | None = None,
        cell_path: list[int] | None = None,
        expression_uuid: str | None = None,
        cell_id: int | None = None,
        cell_tag: str | None = None,
    ) -> NotebookAssistantResult:
        selector = self._resolve_selector(
            notebook_path=notebook_path,
            cell_index=cell_index,
            cell_path=cell_path,
            expression_uuid=expression_uuid,
            cell_id=cell_id,
            cell_tag=cell_tag,
        )

        evaluation = self.runner.evaluate_text(
            self._build_prepare_inline_script(
                notebook_path=notebook_path.resolve(),
                selector=selector,
            ),
            require_front_end=True,
        )

        payload = self._parse_payload(evaluation)
        return NotebookAssistantResult(evaluation=evaluation, payload=payload)

    def capture_inline(
        self,
        *,
        notebook_path: Path,
        cell_index: int | None = None,
        cell_path: list[int] | None = None,
        expression_uuid: str | None = None,
        cell_id: int | None = None,
        cell_tag: str | None = None,
        insert_wolfram_code: bool = False,
        insert_all_wolfram_code: bool = False,
        save_notebook: bool = False,
    ) -> NotebookAssistantResult:
        selector = self._resolve_selector(
            notebook_path=notebook_path,
            cell_index=cell_index,
            cell_path=cell_path,
            expression_uuid=expression_uuid,
            cell_id=cell_id,
            cell_tag=cell_tag,
        )

        insert_mode = self._resolve_insert_mode(
            insert_wolfram_code=insert_wolfram_code,
            insert_all_wolfram_code=insert_all_wolfram_code,
        )

        evaluation = self.runner.evaluate_text(
            self._build_capture_inline_script(
                notebook_path=notebook_path.resolve(),
                selector=selector,
                insert_mode=insert_mode,
                save_notebook=save_notebook,
            ),
            require_front_end=True,
        )

        payload = self._parse_payload(evaluation)
        return NotebookAssistantResult(evaluation=evaluation, payload=payload)

    @staticmethod
    def _resolve_insert_mode(
        *,
        insert_wolfram_code: bool,
        insert_all_wolfram_code: bool,
    ) -> str:
        if insert_all_wolfram_code:
            return "all"
        if insert_wolfram_code:
            return "first"
        return "none"

    def _resolve_selector(
        self,
        *,
        notebook_path: Path,
        cell_index: int | None,
        cell_path: list[int] | None,
        expression_uuid: str | None,
        cell_id: int | None,
        cell_tag: str | None,
    ) -> dict[str, object]:
        selector_count = sum(
            value is not None
            for value in (cell_index, cell_path, expression_uuid, cell_id, cell_tag)
        )
        if selector_count != 1:
            raise ValueError(
                "Exactly one cell selector must be provided: cell index, cell path, expression UUID, cell ID, or cell tag."
            )

        if expression_uuid is not None:
            return {"expression_uuid": expression_uuid}

        if cell_id is not None:
            return {"cell_id": int(cell_id)}

        if cell_tag is not None:
            return {"cell_tag": cell_tag}

        document = NotebookDocument.load(notebook_path)
        row: dict[str, object]
        if cell_index is not None:
            row = document.cell_at_flat_index(cell_index)
        else:
            assert cell_path is not None
            row = document.cell_at_path(cell_path)

        expression_uuid = row.get("expression_uuid")
        if isinstance(expression_uuid, str) and expression_uuid:
            return {"expression_uuid": expression_uuid}

        resolved_cell_id = row.get("cell_id")
        if isinstance(resolved_cell_id, int):
            return {"cell_id": resolved_cell_id}

        tags = row.get("cell_tags")
        if isinstance(tags, list) and tags:
            first_tag = tags[0]
            if isinstance(first_tag, str) and first_tag:
                return {"cell_tag": first_tag}

        resolved_index = row.get("index")
        if isinstance(resolved_index, int):
            return {"cell_index": resolved_index}

        raise ValueError("Unable to resolve the requested notebook cell to a usable selector.")

    def _resolve_row(
        self,
        *,
        notebook_path: Path,
        cell_index: int | None,
        cell_path: list[int] | None,
        expression_uuid: str | None,
        cell_id: int | None,
        cell_tag: str | None,
    ) -> dict[str, object]:
        selector_count = sum(
            value is not None
            for value in (cell_index, cell_path, expression_uuid, cell_id, cell_tag)
        )
        if selector_count != 1:
            raise ValueError(
                "Exactly one cell selector must be provided: cell index, cell path, expression UUID, cell ID, or cell tag."
            )

        document = NotebookDocument.load(notebook_path)
        if cell_index is not None:
            return document.cell_at_flat_index(cell_index)

        if cell_path is not None:
            return document.cell_at_path(cell_path)

        rows = document.flattened_cells()
        if expression_uuid is not None:
            matches = [row for row in rows if row.get("expression_uuid") == expression_uuid]
        elif cell_id is not None:
            matches = [row for row in rows if row.get("cell_id") == int(cell_id)]
        else:
            assert cell_tag is not None
            matches = [
                row
                for row in rows
                if isinstance(row.get("cell_tags"), list) and cell_tag in row["cell_tags"]
            ]

        if len(matches) == 1:
            return matches[0]

        if not matches:
            raise ValueError("The requested notebook cell selector did not match any cell in the notebook file.")

        raise ValueError("The requested notebook cell selector matched more than one cell in the notebook file.")

    def _parse_payload(self, evaluation: KernelEvaluationResult) -> dict[str, object]:
        if not evaluation.evaluation_available:
            return {
                "success": False,
                "error_type": "EvaluationUnavailable",
                "error": evaluation.stderr or "The Wolfram evaluation did not produce a structured payload.",
            }

        if evaluation.success is False:
            return {
                "success": False,
                "error_type": evaluation.failure_type or "KernelEvaluationFailure",
                "error": evaluation.stderr or evaluation.result or "The Wolfram evaluation failed.",
            }

        result = evaluation.result
        if not isinstance(result, str) or not result:
            return {
                "success": False,
                "error_type": "MissingAssistantPayload",
                "error": "The Wolfram evaluation completed but did not return an assistant payload.",
            }

        try:
            payload_text = parse_wl_string_literal(result)
            payload = json.loads(payload_text)
        except Exception as exc:  # pragma: no cover - defensive parsing path
            return {
                "success": False,
                "error_type": "InvalidAssistantPayload",
                "error": f"Unable to parse assistant payload JSON: {exc}",
                "raw_result": result,
            }

        if not isinstance(payload, dict):
            return {
                "success": False,
                "error_type": "InvalidAssistantPayload",
                "error": "The assistant payload was not a JSON object.",
                "raw_payload": payload,
            }

        return payload

    def _finalize_ask_payload(
        self,
        *,
        payload: dict[str, object],
    ) -> dict[str, object]:
        """Postprocess the raw payload from `_build_ask_script`.

        Pulls the assistant's text response and any fenced code blocks
        out of the chat object string, dropping the (now-superfluous)
        raw chat object payload entry. Mirrors `_finalize_ask_cell_payload`
        without the notebook-insertion machinery, since the bare `ask`
        entry point has no source notebook to insert code into.
        """
        if not payload.get("success"):
            return payload

        chat_object_string = payload.get("assistant_chat_object_string")
        if not isinstance(chat_object_string, str) or not chat_object_string:
            return {
                "success": False,
                "error_type": "AssistantResponseUnavailable",
                "error": "Notebook Assistant did not return a chat object string that Tungsten could inspect.",
            }

        response_text = self._extract_assistant_text(chat_object_string)
        if not response_text:
            return {
                "success": False,
                "error_type": "AssistantResponseUnavailable",
                "error": "Notebook Assistant completed, but Tungsten could not extract an assistant text response.",
                "assistant_chat_object_string": chat_object_string,
            }

        code_blocks = self._extract_code_blocks(response_text)
        wolfram_code_blocks = [block for block in code_blocks if bool(block.get("insertable"))]
        enriched = dict(payload)
        enriched["response_text"] = response_text
        enriched["code_blocks"] = code_blocks
        enriched["wolfram_code_blocks"] = wolfram_code_blocks
        enriched.pop("assistant_chat_object_string", None)
        return enriched

    def _finalize_ask_cell_payload(
        self,
        *,
        payload: dict[str, object],
        notebook_path: Path,
        source_row: dict[str, object],
        insert_mode: str,
        save_notebook: bool,
    ) -> dict[str, object]:
        if not payload.get("success"):
            return payload

        chat_object_string = payload.get("assistant_chat_object_string")
        if not isinstance(chat_object_string, str) or not chat_object_string:
            return {
                "success": False,
                "error_type": "AssistantResponseUnavailable",
                "error": "Notebook Assistant did not return a chat object string that Tungsten could inspect.",
                "source_cell": payload.get("source_cell"),
            }

        response_text = self._extract_assistant_text(chat_object_string)
        if not response_text:
            return {
                "success": False,
                "error_type": "AssistantResponseUnavailable",
                "error": "Notebook Assistant completed, but Tungsten could not extract an assistant text response.",
                "source_cell": payload.get("source_cell"),
                "assistant_chat_object_string": chat_object_string,
            }

        code_blocks = self._extract_code_blocks(response_text)
        wolfram_code_blocks = [block for block in code_blocks if bool(block.get("insertable"))]
        insertion_result = self._insert_code_blocks(
            notebook_path=notebook_path,
            source_row=source_row,
            blocks=wolfram_code_blocks,
            insert_mode=insert_mode,
            save_notebook=save_notebook,
        )
        if not insertion_result.get("success", False):
            return {
                "success": False,
                "error_type": insertion_result.get("error_type", "InsertionFailure"),
                "error": insertion_result.get("error", "Tungsten could not insert the generated Wolfram code."),
                "source_cell": payload.get("source_cell"),
                "response_text": response_text,
                "code_blocks": code_blocks,
                "wolfram_code_blocks": wolfram_code_blocks,
            }

        enriched = dict(payload)
        enriched["response_text"] = response_text
        enriched["code_blocks"] = code_blocks
        enriched["wolfram_code_blocks"] = wolfram_code_blocks
        enriched["insert_mode"] = insert_mode
        enriched["inserted"] = insertion_result.get("inserted", [])
        enriched["saved_notebook"] = bool(insertion_result.get("saved_notebook"))
        enriched.pop("assistant_chat_object_string", None)
        return enriched

    @staticmethod
    def _decode_chat_string(value: str) -> str:
        try:
            decoded = json.loads(f'"{value}"')
        except json.JSONDecodeError:
            decoded = value

        if any(token in decoded for token in ("\\n", "\\t", '\\"', "\\\\")):
            try:
                return bytes(decoded, "utf-8").decode("unicode_escape")
            except UnicodeDecodeError:
                return decoded

        return decoded

    def _extract_assistant_text(self, chat_object_string: str) -> str:
        assistant_sections = re.findall(
            r'<\|"Role"\s*->\s*"Assistant".*?"Content"\s*->\s*\{(.*?)\}\s*,\s*"Metadata"\s*->',
            chat_object_string,
            flags=re.DOTALL,
        )
        if not assistant_sections:
            return ""

        data_chunks = re.findall(
            r'"Type"\s*->\s*"Text"\s*,\s*"Data"\s*->\s*"(.*?)"',
            assistant_sections[-1],
            flags=re.DOTALL,
        )
        if not data_chunks:
            return ""

        decoded = [self._decode_chat_string(chunk) for chunk in data_chunks]
        return "\n\n".join(part for part in decoded if part)

    def _extract_code_blocks(self, response_text: str) -> list[dict[str, object]]:
        matches = re.finditer(
            r"```(?P<language>[^\n`]*)\n(?P<code>.*?)```",
            response_text,
            flags=re.DOTALL,
        )
        blocks: list[dict[str, object]] = []
        for index, match in enumerate(matches):
            language_raw = match.group("language").strip()
            normalized = re.sub(r"\s+", " ", language_raw).strip().lower()
            insertable = normalized in {
                "wolfram",
                "wolfram language",
                "wolframlanguage",
                "mathematica",
                "wl",
            }
            blocks.append(
                {
                    "index": index,
                    "language": language_raw or "Unknown",
                    "code": match.group("code").strip(),
                    "insertable": insertable,
                }
            )
        return blocks

    def _insert_code_blocks(
        self,
        *,
        notebook_path: Path,
        source_row: dict[str, object],
        blocks: list[dict[str, object]],
        insert_mode: str,
        save_notebook: bool,
    ) -> dict[str, object]:
        if insert_mode == "none" or not blocks:
            return {"success": True, "inserted": [], "saved_notebook": False}

        selected = blocks if insert_mode == "all" else blocks[:1]
        code_strings = [block["code"] for block in selected if isinstance(block.get("code"), str) and block["code"]]
        if not code_strings:
            return {"success": True, "inserted": [], "saved_notebook": False}

        selector = self._selector_from_row(source_row)
        evaluation = self.runner.evaluate_text(
            self._build_insert_script(
                notebook_path=notebook_path.resolve(),
                selector=selector,
                code_strings=code_strings,
                save_notebook=save_notebook,
            ),
            require_front_end=True,
        )
        payload = self._parse_payload(evaluation)
        if not payload.get("success"):
            return payload

        return {
            "success": True,
            "inserted": payload.get("inserted", []),
            "saved_notebook": bool(payload.get("saved_notebook")),
        }

    @staticmethod
    def _selector_from_row(row: dict[str, object]) -> dict[str, object]:
        expression_uuid = row.get("expression_uuid")
        if isinstance(expression_uuid, str) and expression_uuid:
            return {"expression_uuid": expression_uuid}

        cell_id = row.get("cell_id")
        if isinstance(cell_id, int):
            return {"cell_id": cell_id}

        tags = row.get("cell_tags")
        if isinstance(tags, list) and tags:
            first_tag = tags[0]
            if isinstance(first_tag, str) and first_tag:
                return {"cell_tag": first_tag}

        index = row.get("index")
        if isinstance(index, int):
            return {"cell_index": index}

        raise ValueError("Tungsten could not derive a stable cell selector from the notebook row.")

    def _build_ask_script(
        self,
        *,
        prompt: str,
        system_prompt: str | None,
        extra_instructions: str | None,
        model_service: str | None,
        model_name: str | None,
        tools: list[str] | None,
    ) -> str:
        """Wolfram script for the bare `ask` entry point.

        Creates a hidden temporary chat notebook, writes the prompt as
        a ChatInput cell, evaluates it via `Wolfram`Chatbook`ChatCellEvaluate`,
        captures the chat object as an InputForm string, closes the
        notebook, and emits an `ExportString[..., "RawJSON"]` payload
        that `_parse_payload` understands.

        Unlike `_build_script`, this path has no source notebook to
        bind to and no source cell to embed - it's purely
        ask-the-assistant-a-question, returning the assistant's text
        answer plus any fenced code blocks.
        """
        settings: dict[str, object] = {
            "AutoSaveConversations": False,
            "Tools": list(tools) if tools is not None else [
                "WolframLanguageEvaluator",
                "DocumentationSearcher",
                "WolframAlpha",
            ],
        }
        if model_service is not None or model_name is not None:
            settings["Model"] = {
                "Service": model_service if model_service is not None else "Automatic",
                "Name": model_name if model_name is not None else "Automatic",
            }
        settings_json = json.dumps(settings, ensure_ascii=True)

        combined_instructions = (extra_instructions or "").strip()
        system_prompt_text = (system_prompt or "").strip()

        return f"""
Needs["Wolfram`Chatbook`" -> None];

tungstenSettings = ImportString[{wl_string(settings_json)}, "RawJSON"];
tungstenPrompt = {wl_string(prompt)};
tungstenSystemPrompt = {wl_string(system_prompt_text)};
tungstenExtraInstructions = {wl_string(combined_instructions)};

tungstenChatCellEvaluate = Symbol["Wolfram`Chatbook`ChatCellEvaluate"];

ClearAll[tungstenError, tungstenChatSettings];

tungstenError[type_String, message_String, extra_: <||>] :=
    Join[<|"success" -> False, "error_type" -> type, "error" -> message|>, extra];

tungstenChatSettings[nbo_NotebookObject] := Quiet @ Check[
    CurrentValue[nbo, {{TaggingRules, "ChatNotebookSettings"}}] = tungstenSettings,
    Null
];

tungstenResult = Module[
    {{assistantNotebook, chatCell, chatObject, chatRaw, combinedPrompt}},

    combinedPrompt = Which[
        tungstenSystemPrompt =!= "" && tungstenExtraInstructions =!= "",
            tungstenSystemPrompt <> "\\n\\n" <> tungstenPrompt <> "\\n\\n" <> tungstenExtraInstructions,
        tungstenSystemPrompt =!= "",
            tungstenSystemPrompt <> "\\n\\n" <> tungstenPrompt,
        tungstenExtraInstructions =!= "",
            tungstenPrompt <> "\\n\\n" <> tungstenExtraInstructions,
        True,
            tungstenPrompt
    ];

    assistantNotebook = Quiet @ Check[
        CreateDocument[
            Notebook[{{Cell["Tungsten Assistant Ask Session", "Section"]}}],
            Visible -> False
        ],
        $Failed
    ];
    If[
        ! MatchQ[assistantNotebook, _NotebookObject],
        tungstenError[
            "AssistantNotebookCreateFailed",
            "Tungsten could not create the temporary Notebook Assistant notebook."
        ],
        (
            tungstenChatSettings @ assistantNotebook;
            SelectionMove[assistantNotebook, After, Notebook, AutoScroll -> False];
            NotebookWrite[
                assistantNotebook,
                Cell[combinedPrompt, "ChatInput"]
            ];
            chatCell = Quiet @ Check[Last[Cells[assistantNotebook]], $Failed];
            chatObject = Quiet @ Check[
                If[MatchQ[chatCell, _CellObject],
                    tungstenChatCellEvaluate[chatCell, assistantNotebook],
                    $Failed],
                $Failed
            ];
            chatRaw = ToString[chatObject, InputForm, PageWidth -> Infinity];
            Quiet @ Check[NotebookClose @ assistantNotebook, Null];

            <|
                "success" -> True,
                "prompt" -> tungstenPrompt,
                "assistant_chat_object_string" -> chatRaw
            |>
        )
    ]
];

ExportString[tungstenResult, "RawJSON"]
""".strip()

    def _build_script(
        self,
        *,
        notebook_path: Path,
        question: str,
        selector: dict[str, object],
        insert_mode: str,
        save_notebook: bool,
        close_assistant_notebook: bool,
        extra_instructions: str | None,
        model_service: str | None,
        model_name: str | None,
    ) -> str:
        selector_json = json.dumps(selector, ensure_ascii=True)
        settings: dict[str, object] = {
            "AutoSaveConversations": False,
            "Tools": [
                "WolframLanguageEvaluator",
                "DocumentationSearcher",
                "WolframAlpha",
            ],
        }
        if model_service is not None or model_name is not None:
            settings["Model"] = {
                "Service": model_service if model_service is not None else "Automatic",
                "Name": model_name if model_name is not None else "Automatic",
            }

        settings_json = json.dumps(settings, ensure_ascii=True)
        default_instructions = (
            "Do not modify the notebook directly or use notebook-editing tools. "
            "Answer in chat only. If you provide Wolfram Language code, place it in a Wolfram Language code block."
        )
        combined_instructions = default_instructions
        if extra_instructions:
            combined_instructions = f"{default_instructions}\n\n{extra_instructions}"

        return f"""
Needs["Wolfram`Chatbook`" -> None];

tungstenSelector = ImportString[{wl_string(selector_json)}, "RawJSON"];
tungstenSettings = ImportString[{wl_string(settings_json)}, "RawJSON"];
tungstenQuestion = {wl_string(question)};
tungstenNotebookPath = {wl_string(notebook_path.as_posix())};
tungstenExtraInstructions = {wl_string(combined_instructions)};

tungstenChatCellEvaluate = Symbol["Wolfram`Chatbook`ChatCellEvaluate"];
tungstenCellToString = Symbol["Wolfram`Chatbook`CellToString"];

{_assistant_helper_block(
    preview_expression="tungstenCellToString @ cellExpr",
    extra_clear_names=(
        "tungstenPromptCell",
        "tungstenChatSettings",
    ),
)}

tungstenPromptCell[sourceCell_CellObject] := Module[
    {{sourceExpr, sourceText, sourceStyle, styleText}},
    sourceExpr = Quiet @ Check[NotebookRead @ sourceCell, $Failed];
    sourceText = Quiet @ Check[
        tungstenCellToString @ sourceExpr,
        ToString[sourceExpr, InputForm, PageWidth -> Infinity]
    ];
    sourceStyle = tungstenStringValue @ CurrentValue[sourceCell, CellStyle];
    styleText = Replace[sourceStyle, {{s_String :> s, _ :> "Unknown"}}];
    Cell[
        StringJoin[
            tungstenQuestion,
            "\\n\\n",
            "Source notebook cell style: ",
            styleText,
            "\\n\\n",
            "Source notebook cell contents:\\n",
            sourceText,
            "\\n\\n",
            tungstenExtraInstructions
        ],
        "ChatInput"
    ]
];

tungstenChatSettings[nbo_NotebookObject] := Quiet @ Check[
    CurrentValue[nbo, {{TaggingRules, "ChatNotebookSettings"}}] = tungstenSettings,
    Null
];

tungstenResult = Module[
    {{sourceNotebook, sourceCell, assistantNotebook, promptCell, chatCell, chatObject, chatRaw}},

    sourceNotebook = tungstenResolveNotebook @ tungstenNotebookPath;
    If[
        AssociationQ @ sourceNotebook,
        sourceNotebook,
        (
            SetSelectedNotebook @ sourceNotebook;
            sourceCell = tungstenResolveCell[sourceNotebook, tungstenSelector];
            If[
                AssociationQ @ sourceCell,
                sourceCell,
                (
                    assistantNotebook = Quiet @ Check[
                        CreateDocument[
                            Notebook[{{Cell["Tungsten Notebook Assistant Session", "Section"]}}],
                            Visible -> False
                        ],
                        $Failed
                    ];
                    If[
                        ! MatchQ[assistantNotebook, _NotebookObject],
                        tungstenError[
                            "AssistantNotebookCreateFailed",
                            "Tungsten could not create the temporary Notebook Assistant notebook."
                        ],
                        (
                            tungstenChatSettings @ assistantNotebook;
                            SelectionMove[assistantNotebook, After, Notebook, AutoScroll -> False];
                            NotebookWrite[
                                assistantNotebook,
                                Cell[
                                    StringJoin[
                                        "You are answering a question about a specific cell from a Wolfram notebook.",
                                        "\\n\\n",
                                        "Answer the user's question directly.",
                                        "\\n\\n",
                                        "If you provide Wolfram Language code, place it in a Wolfram Language code block."
                                    ],
                                    "Text"
                                ]
                            ];
                            SelectionMove[assistantNotebook, After, Notebook, AutoScroll -> False];
                            NotebookWrite[
                                assistantNotebook,
                                Cell[
                                    StringJoin[
                                        "Source notebook path: ",
                                        tungstenNotebookPath
                                    ],
                                    "Text"
                                ]
                            ];
                            SelectionMove[assistantNotebook, After, Notebook, AutoScroll -> False];
                            promptCell = tungstenPromptCell @ sourceCell;
                            NotebookWrite[assistantNotebook, promptCell];
                            chatCell = Quiet @ Check[Last[Cells[assistantNotebook]], $Failed];
                            chatObject = Quiet @ Check[
                                If[MatchQ[chatCell, _CellObject], tungstenChatCellEvaluate[chatCell, assistantNotebook], $Failed],
                                $Failed
                            ];
                            chatRaw = ToString[chatObject, InputForm, PageWidth -> Infinity];
                            Quiet @ Check[NotebookClose @ assistantNotebook, Null];

                            <|
                                "success" -> True,
                                "notebook_path" -> tungstenNotebookPath,
                                "question" -> tungstenQuestion,
                                "selector" -> tungstenSelector,
                                "source_cell" -> tungstenCellMetadata @ sourceCell,
                                "assistant_notebook_mode" -> "TemporaryHiddenChatNotebook",
                                "assistant_notebook_closed" -> True,
                                "assistant_chat_object_string" -> chatRaw
                            |>
                        )
                    ]
                )
            ]
        )
    ]
];

ExportString[tungstenResult, "RawJSON"]
""".strip()

    def _build_insert_script(
        self,
        *,
        notebook_path: Path,
        selector: dict[str, object],
        code_strings: list[str],
        save_notebook: bool,
    ) -> str:
        selector_json = json.dumps(selector, ensure_ascii=True)
        codes_json = json.dumps(code_strings, ensure_ascii=True)
        return f"""
tungstenSelector = ImportString[{wl_string(selector_json)}, "RawJSON"];
tungstenCodes = ImportString[{wl_string(codes_json)}, "RawJSON"];
tungstenNotebookPath = {wl_string(notebook_path.as_posix())};
tungstenSaveNotebook = {"True" if save_notebook else "False"};

{_assistant_helper_block(preview_expression="ToString[cellExpr, InputForm, PageWidth -> Infinity]")}

tungstenResult = Module[
    {{sourceNotebook, sourceCell, insertionPoint, inserted = {{}}, code, uuid, insertedCell}},
    sourceNotebook = tungstenResolveNotebook @ tungstenNotebookPath;
    If[
        AssociationQ @ sourceNotebook,
        sourceNotebook,
        (
            sourceCell = tungstenResolveCell[sourceNotebook, tungstenSelector];
            If[
                AssociationQ @ sourceCell,
                sourceCell,
                (
                    insertionPoint = sourceCell;
                    Do[
                        uuid = CreateUUID[];
                        SelectionMove[insertionPoint, After, Cell, AutoScroll -> False];
                        NotebookWrite[
                            sourceNotebook,
                            Cell[code, "Input", ExpressionUUID -> uuid],
                            All,
                            AutoScroll -> False
                        ];
                        insertedCell = Quiet @ Check[First[Cells[sourceNotebook, ExpressionUUID -> uuid]], None];
                        If[MatchQ[insertedCell, _CellObject], insertionPoint = insertedCell];
                        AppendTo[
                            inserted,
                            <|
                                "expression_uuid" -> uuid,
                                "cell_id" -> Replace[
                                    If[MatchQ[insertedCell, _CellObject], CurrentValue[insertedCell, CellID], Null],
                                    {{value_Integer :> value, _ :> Null}}
                                ],
                                "code" -> code
                            |>
                        ];
                        ,
                        {{code, tungstenCodes}}
                    ];

                    If[TrueQ @ tungstenSaveNotebook, NotebookSave @ sourceNotebook];

                    <|
                        "success" -> True,
                        "source_cell" -> tungstenCellMetadata @ sourceCell,
                        "inserted" -> inserted,
                        "saved_notebook" -> TrueQ @ tungstenSaveNotebook
                    |>
                )
            ]
        )
    ]
];

ExportString[tungstenResult, "RawJSON"]
""".strip()

    def _build_prepare_inline_script(
        self,
        *,
        notebook_path: Path,
        selector: dict[str, object],
    ) -> str:
        selector_json = json.dumps(selector, ensure_ascii=True)
        return f"""
Needs["Wolfram`Chatbook`" -> None];

tungstenSelector = ImportString[{wl_string(selector_json)}, "RawJSON"];
tungstenNotebookPath = {wl_string(notebook_path.as_posix())};
tungstenShowNotebookAssistance = Symbol["Wolfram`Chatbook`ShowNotebookAssistance"];
tungstenCellToString = Symbol["Wolfram`Chatbook`CellToString"];
{_assistant_helper_block(preview_expression="tungstenCellToString @ cellExpr")}

tungstenResult = Module[
    {{sourceNotebook, sourceCell, attachedCell}},
    sourceNotebook = tungstenResolveNotebook @ tungstenNotebookPath;
    If[
        AssociationQ @ sourceNotebook,
        sourceNotebook,
        (
            SetSelectedNotebook @ sourceNotebook;
            sourceCell = tungstenResolveCell[sourceNotebook, tungstenSelector];
            If[
                AssociationQ @ sourceCell,
                sourceCell,
                (
                    SelectionMove[sourceCell, All, Cell, AutoScroll -> True];
                    attachedCell = Quiet @ Check[
                        tungstenShowNotebookAssistance[sourceCell, "Inline", EvaluateInput -> False],
                        $Failed
                    ];
                    If[
                        ! MatchQ[attachedCell, _CellObject],
                        tungstenError[
                            "InlineAssistantOpenFailed",
                            "Notebook Assistant inline input was not created."
                        ],
                        (
                            SelectionMove[attachedCell, Before, Cell, AutoScroll -> True];
                            FrontEnd`MoveCursorToInputField[sourceNotebook, "AttachedChatInputField"];
                            <|
                                "success" -> True,
                                "notebook_path" -> tungstenNotebookPath,
                                "window_title" -> Replace[
                                    Quiet @ Check[CurrentValue[sourceNotebook, WindowTitle], None],
                                    {{s_String :> s, _ :> Null}}
                                ],
                                "source_cell" -> tungstenCellMetadata @ sourceCell,
                                "inline_cell_style" -> tungstenStringValue @ CurrentValue[attachedCell, CellStyle]
                            |>
                        )
                    ]
                )
            ]
        )
    ]
];

ExportString[tungstenResult, "RawJSON"]
""".strip()

    def _build_capture_inline_script(
        self,
        *,
        notebook_path: Path,
        selector: dict[str, object],
        insert_mode: str,
        save_notebook: bool,
    ) -> str:
        selector_json = json.dumps(selector, ensure_ascii=True)
        return f"""
Needs["Wolfram`Chatbook`" -> None];

tungstenSelector = ImportString[{wl_string(selector_json)}, "RawJSON"];
tungstenNotebookPath = {wl_string(notebook_path.as_posix())};
tungstenInsertMode = {wl_string(insert_mode)};
tungstenSaveNotebook = {"True" if save_notebook else "False"};

tungstenCellToString = Symbol["Wolfram`Chatbook`CellToString"];
tungstenGetCodeBlockContent = Symbol["Wolfram`Chatbook`Formatting`Private`getCodeBlockContent"];
tungstenInsertAfterChatGeneratedCells = Symbol["Wolfram`Chatbook`Formatting`Private`insertAfterChatGeneratedCells"];
{_assistant_helper_block(
    preview_expression="tungstenCellToString @ cellExpr",
    extra_clear_names=(
        "tungstenFindInlineCell",
        "tungstenCodeCellData",
        "tungstenCodeBlocksFromExpression",
        "tungstenInsertBlocks",
    ),
)}

tungstenFindInlineCell[nbo_NotebookObject, source_CellObject] := Module[
    {{attached, marker}},
    attached = Cells[source, AttachedCell -> True, CellStyle -> "AttachedChatInput"];
    If[attached === {{}}, attached = Cells[nbo, AttachedCell -> True, CellStyle -> "AttachedChatInput"]];
    If[attached === {{}}, Return[None]];
    marker = ToString[source, InputForm, PageWidth -> Infinity];
    SelectFirst[
        attached,
        Quiet @ Check[
            StringContainsQ[ToString[NotebookRead[#], InputForm, PageWidth -> Infinity], marker],
            False
        ] &,
        First[attached]
    ]
];

tungstenCodeCellData[cell_Cell] := Module[
    {{content, language}},
    content = tungstenGetCodeBlockContent @ cell;
    language = Which[
        MatchQ[content, Cell[_, "Input", ___]], "WolframLanguage",
        MatchQ[content, Cell[_, "ExternalLanguage", ___, CellEvaluationLanguage -> lang_, ___]],
            "ExternalLanguage:" <> ToString[lang, InputForm, PageWidth -> Infinity],
        True,
            "Unknown"
    ];
    <|
        "language" -> language,
        "code" -> Quiet @ Check[
            tungstenCellToString @ content,
            ToString[content, InputForm, PageWidth -> Infinity]
        ],
        "cell_expression" -> ToString[content, InputForm, PageWidth -> Infinity],
        "insertable" -> MatchQ[content, Cell[_, "Input", ___]],
        "cell" -> content
    |>
];

tungstenCodeBlocksFromExpression[expr_] := Module[
    {{rawBlocks}},
    rawBlocks = Cases[expr, block : Cell[_, "ChatCodeBlock", ___] :> block, Infinity];
    tungstenCodeCellData /@ rawBlocks
];

tungstenInsertBlocks[source_CellObject, blocks_List, mode_String] := Module[
    {{selected, inserted = {{}}, targetNotebook, insertionPoint, blockData, uuid, prepared, insertedCell}},
    selected = Switch[mode, "all", blocks, "first", Take[blocks, UpTo[1]], _, {{}}];
    If[selected === {{}}, Return[inserted]];

    targetNotebook = ParentNotebook @ source;
    insertionPoint = source;

    Do[
        uuid = CreateUUID[];
        prepared = Replace[blockData["cell"], Cell[a___] :> Cell[a, ExpressionUUID -> uuid]];
        tungstenInsertAfterChatGeneratedCells[insertionPoint, prepared];
        insertedCell = Quiet @ Check[First[Cells[targetNotebook, ExpressionUUID -> uuid]], None];
        If[MatchQ[insertedCell, _CellObject], insertionPoint = insertedCell];
        AppendTo[
            inserted,
            <|
                "expression_uuid" -> uuid,
                "cell_id" -> Replace[
                    If[MatchQ[insertedCell, _CellObject], CurrentValue[insertedCell, CellID], Null],
                    {{value_Integer :> value, _ :> Null}}
                ],
                "code" -> blockData["code"]
            |>
        ];
        ,
        {{blockData, selected}}
    ];

    inserted
];

tungstenResult = Module[
    {{
        sourceNotebook,
        sourceCell,
        attachedCell,
        attachedExpr,
        inputString,
        outputCells,
        responseText,
        allCodeBlockData,
        wlCodeBlocks,
        inserted,
        hasProgress,
        completed
    }},

    sourceNotebook = tungstenResolveNotebook @ tungstenNotebookPath;
    If[
        AssociationQ @ sourceNotebook,
        sourceNotebook,
        (
            sourceCell = tungstenResolveCell[sourceNotebook, tungstenSelector];
            If[
                AssociationQ @ sourceCell,
                sourceCell,
                (
                    attachedCell = tungstenFindInlineCell[sourceNotebook, sourceCell];
                    If[
                        ! MatchQ[attachedCell, _CellObject],
                        tungstenError[
                            "InlineAssistantNotFound",
                            "No inline Notebook Assistant input is currently attached to the requested source cell."
                        ],
                        (
                            attachedExpr = Quiet @ Check[NotebookRead @ attachedCell, $Failed];
                            inputString = Quiet @ Check[
                                CurrentValue[attachedCell, {{TaggingRules, "ChatInputString"}}],
                                ""
                            ];
                            outputCells = Cases[attachedExpr, cell : Cell[_, "ChatOutput", ___] :> cell, Infinity];
                            responseText = StringRiffle[
                                Cases[
                                    outputCells,
                                    cell_Cell :> Quiet @ Check[tungstenCellToString @ cell, ""]
                                ],
                                "\\n\\n"
                            ];
                            allCodeBlockData = tungstenCodeBlocksFromExpression @ attachedExpr;
                            wlCodeBlocks = Select[allCodeBlockData, TrueQ @ #["insertable"] &];
                            hasProgress = ! FreeQ[attachedExpr, _ProgressIndicator | _ProgressIndicatorBox, Infinity];
                            completed = StringQ[inputString] && inputString == "" && Length[outputCells] > 0 && ! hasProgress;

                            inserted = If[
                                completed && tungstenInsertMode =!= "none",
                                tungstenInsertBlocks[sourceCell, wlCodeBlocks, tungstenInsertMode],
                                {{}}
                            ];

                            If[TrueQ @ tungstenSaveNotebook && inserted =!= {{}}, NotebookSave @ sourceNotebook];

                            <|
                                "success" -> True,
                                "completed" -> completed,
                                "has_progress_indicator" -> hasProgress,
                                "inline_attached" -> True,
                                "notebook_path" -> tungstenNotebookPath,
                                "window_title" -> Replace[
                                    Quiet @ Check[CurrentValue[sourceNotebook, WindowTitle], None],
                                    {{s_String :> s, _ :> Null}}
                                ],
                                "source_cell" -> tungstenCellMetadata @ sourceCell,
                                "input_string" -> tungstenStringValue @ inputString,
                                "response_text" -> responseText,
                                "assistant_output_count" -> Length[outputCells],
                                "code_blocks" -> MapIndexed[
                                    Append[KeyDrop[#, "cell"], "index" -> First[#2]] &,
                                    allCodeBlockData
                                ],
                                "wolfram_code_blocks" -> MapIndexed[
                                    Append[KeyDrop[#, "cell"], "index" -> First[#2]] &,
                                    wlCodeBlocks
                                ],
                                "insert_mode" -> tungstenInsertMode,
                                "inserted" -> inserted,
                                "saved_notebook" -> TrueQ @ tungstenSaveNotebook && inserted =!= {{}}
                            |>
                        )
                    ]
                )
            ]
        )
    ]
];

ExportString[tungstenResult, "RawJSON"]
""".strip()
