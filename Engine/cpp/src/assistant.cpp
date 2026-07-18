#include "tungsten/assistant.hpp"
#include "tungsten/detail/ascii.hpp"

#include "tungsten/wolfram_strings.hpp"

#include <algorithm>
#include <filesystem>
#include <limits>
#include <sstream>
#include <type_traits>
#include <utility>

namespace tungsten {
namespace {

namespace fs = std::filesystem;

constexpr const char* default_instructions =
    "Do not modify the notebook directly or use notebook-editing tools. "
    "Answer in chat only. If you provide Wolfram Language code, place it in a "
    "Wolfram Language code block.";

const std::vector<std::string> default_tools{
    "WolframLanguageEvaluator", "DocumentationSearcher", "WolframAlpha"};

const char* assistant_helpers_template = R"WL(ClearAll[
    tungstenError,
    tungstenStringValue,
    tungstenStringList,
    tungstenCompactText,
    tungstenCellMetadata,
    tungstenFindNotebook,
    tungstenResolveNotebook,
    tungstenResolveCell__EXTRA_CLEAR__
];

tungstenError[type_String, message_String, extra_: <||>] :=
    Join[<|"success" -> False, "error_type" -> type, "error" -> message|>, extra];

tungstenStringValue[value_] := Replace[value, {
    None | Null | Inherited | Missing[__] -> Null,
    s_String :> s,
    other_ :> ToString[Unevaluated[other], InputForm, PageWidth -> Infinity]
}];
tungstenStringList[value_] := Replace[value, {
    s_String :> {s}, list_List :> Cases[list, tag_String :> tag, Infinity], _ :> {}
}];
tungstenCompactText[text_String] := StringTake[
    StringTrim @ StringReplace[text, WhitespaceCharacter .. -> " "], UpTo[240]];
tungstenCellMetadata[cell_CellObject] := Module[{cellExpr, preview},
    cellExpr = Quiet @ Check[NotebookRead @ cell, $Failed];
    preview = Quiet @ Check[__PREVIEW__, ""];
    <|
        "expression_uuid" -> tungstenStringValue @ CurrentValue[cell, ExpressionUUID],
        "cell_id" -> Replace[CurrentValue[cell, CellID], {value_Integer :> value, _ :> Null}],
        "cell_tags" -> tungstenStringList @ CurrentValue[cell, CellTags],
        "style" -> tungstenStringValue @ CurrentValue[cell, CellStyle],
        "preview" -> tungstenCompactText @ Replace[preview, Except[_String] :> ""]
    |>
];
tungstenFindNotebook[path_String] := SelectFirst[Notebooks[],
    Quiet @ Check[NotebookFileName[#] === path, False] &, Missing["NotFound"]];
tungstenResolveNotebook[path_String] := Module[{existing, opened},
    existing = tungstenFindNotebook @ path;
    If[MatchQ[existing, _NotebookObject], Return[existing]];
    opened = Quiet @ Check[NotebookOpen[path], $Failed];
    If[MatchQ[opened, _NotebookObject], opened,
        tungstenError["NotebookOpenFailed", "Unable to open the requested notebook.",
            <|"notebook_path" -> path|>]]
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
            allCells = Cells[nbo]; cellIndex = selector["cell_index"] + 1;
            matches = If[1 <= cellIndex <= Length[allCells], {allCells[[cellIndex]]}, {}],
        True, matches = {}
    ];
    Which[
        Length[matches] == 1, First[matches],
        Length[matches] == 0,
            tungstenError["CellNotFound", "No notebook cell matched the requested selector.",
                <|"selector" -> selector|>],
        True,
            tungstenError["AmbiguousCellSelector",
                "More than one notebook cell matched the requested selector.",
                <|"selector" -> selector, "match_count" -> Length[matches]|>]
    ]
];)WL";

const char* ask_script_template = R"WL(Needs["Wolfram`Chatbook`" -> None];

tungstenSettings = ImportString[__SETTINGS__, "RawJSON"];
tungstenPrompt = __PROMPT__;
tungstenSystemPrompt = __SYSTEM_PROMPT__;
tungstenExtraInstructions = __EXTRA_INSTRUCTIONS__;
tungstenChatCellEvaluate = Symbol["Wolfram`Chatbook`ChatCellEvaluate"];

ClearAll[tungstenError, tungstenChatSettings];
tungstenError[type_String, message_String, extra_: <||>] :=
    Join[<|"success" -> False, "error_type" -> type, "error" -> message|>, extra];
tungstenChatSettings[nbo_NotebookObject] := Quiet @ Check[
    CurrentValue[nbo, {TaggingRules, "ChatNotebookSettings"}] = tungstenSettings, Null];

tungstenResult = Module[{assistantNotebook, chatCell, chatObject, chatRaw, combinedPrompt},
    combinedPrompt = Which[
        tungstenSystemPrompt =!= "" && tungstenExtraInstructions =!= "",
            tungstenSystemPrompt <> "\n\n" <> tungstenPrompt <> "\n\n" <> tungstenExtraInstructions,
        tungstenSystemPrompt =!= "", tungstenSystemPrompt <> "\n\n" <> tungstenPrompt,
        tungstenExtraInstructions =!= "", tungstenPrompt <> "\n\n" <> tungstenExtraInstructions,
        True, tungstenPrompt
    ];
    assistantNotebook = Quiet @ Check[CreateDocument[
        Notebook[{Cell["Tungsten Assistant Ask Session", "Section"]}], Visible -> False], $Failed];
    If[!MatchQ[assistantNotebook, _NotebookObject],
        tungstenError["AssistantNotebookCreateFailed",
            "Tungsten could not create the temporary Notebook Assistant notebook."],
        tungstenChatSettings @ assistantNotebook;
        SelectionMove[assistantNotebook, After, Notebook, AutoScroll -> False];
        NotebookWrite[assistantNotebook, Cell[combinedPrompt, "ChatInput"]];
        chatCell = Quiet @ Check[Last[Cells[assistantNotebook]], $Failed];
        chatObject = Quiet @ Check[If[MatchQ[chatCell, _CellObject],
            tungstenChatCellEvaluate[chatCell, assistantNotebook], $Failed], $Failed];
        chatRaw = ToString[chatObject, InputForm, PageWidth -> Infinity];
        Quiet @ Check[NotebookClose @ assistantNotebook, Null];
        <|"success" -> True, "prompt" -> tungstenPrompt,
          "assistant_chat_object_string" -> chatRaw|>
    ]
];
ExportString[tungstenResult, "RawJSON"])WL";

const char* ask_cell_script_template = R"WL(Needs["Wolfram`Chatbook`" -> None];

tungstenSelector = ImportString[__SELECTOR__, "RawJSON"];
tungstenSettings = ImportString[__SETTINGS__, "RawJSON"];
tungstenQuestion = __QUESTION__;
tungstenNotebookPath = __NOTEBOOK_PATH__;
tungstenExtraInstructions = __INSTRUCTIONS__;
tungstenChatCellEvaluate = Symbol["Wolfram`Chatbook`ChatCellEvaluate"];
tungstenCellToString = Symbol["Wolfram`Chatbook`CellToString"];

__HELPERS__

tungstenPromptCell[sourceCell_CellObject] := Module[{sourceExpr, sourceText, sourceStyle, styleText},
    sourceExpr = Quiet @ Check[NotebookRead @ sourceCell, $Failed];
    sourceText = Quiet @ Check[tungstenCellToString @ sourceExpr,
        ToString[sourceExpr, InputForm, PageWidth -> Infinity]];
    sourceStyle = tungstenStringValue @ CurrentValue[sourceCell, CellStyle];
    styleText = Replace[sourceStyle, {s_String :> s, _ :> "Unknown"}];
    Cell[StringJoin[tungstenQuestion, "\n\n", "Source notebook cell style: ", styleText,
        "\n\n", "Source notebook cell contents:\n", sourceText, "\n\n",
        tungstenExtraInstructions], "ChatInput"]
];
tungstenChatSettings[nbo_NotebookObject] := Quiet @ Check[
    CurrentValue[nbo, {TaggingRules, "ChatNotebookSettings"}] = tungstenSettings, Null];

tungstenResult = Module[
    {sourceNotebook, sourceCell, assistantNotebook, promptCell, chatCell, chatObject, chatRaw},
    sourceNotebook = tungstenResolveNotebook @ tungstenNotebookPath;
    If[AssociationQ @ sourceNotebook, sourceNotebook,
        SetSelectedNotebook @ sourceNotebook;
        sourceCell = tungstenResolveCell[sourceNotebook, tungstenSelector];
        If[AssociationQ @ sourceCell, sourceCell,
            assistantNotebook = Quiet @ Check[CreateDocument[
                Notebook[{Cell["Tungsten Notebook Assistant Session", "Section"]}],
                Visible -> False], $Failed];
            If[!MatchQ[assistantNotebook, _NotebookObject],
                tungstenError["AssistantNotebookCreateFailed",
                    "Tungsten could not create the temporary Notebook Assistant notebook."],
                tungstenChatSettings @ assistantNotebook;
                SelectionMove[assistantNotebook, After, Notebook, AutoScroll -> False];
                NotebookWrite[assistantNotebook, Cell[StringJoin[
                    "You are answering a question about a specific cell from a Wolfram notebook.",
                    "\n\n", "Answer the user's question directly.", "\n\n",
                    "If you provide Wolfram Language code, place it in a Wolfram Language code block."], "Text"]];
                SelectionMove[assistantNotebook, After, Notebook, AutoScroll -> False];
                NotebookWrite[assistantNotebook,
                    Cell["Source notebook path: " <> tungstenNotebookPath, "Text"]];
                SelectionMove[assistantNotebook, After, Notebook, AutoScroll -> False];
                promptCell = tungstenPromptCell @ sourceCell;
                NotebookWrite[assistantNotebook, promptCell];
                chatCell = Quiet @ Check[Last[Cells[assistantNotebook]], $Failed];
                chatObject = Quiet @ Check[If[MatchQ[chatCell, _CellObject],
                    tungstenChatCellEvaluate[chatCell, assistantNotebook], $Failed], $Failed];
                chatRaw = ToString[chatObject, InputForm, PageWidth -> Infinity];
                Quiet @ Check[NotebookClose @ assistantNotebook, Null];
                <|"success" -> True, "notebook_path" -> tungstenNotebookPath,
                  "question" -> tungstenQuestion, "selector" -> tungstenSelector,
                  "source_cell" -> tungstenCellMetadata @ sourceCell,
                  "assistant_notebook_mode" -> "TemporaryHiddenChatNotebook",
                  "assistant_notebook_closed" -> True,
                  "assistant_chat_object_string" -> chatRaw|>
            ]
        ]
    ]
];
ExportString[tungstenResult, "RawJSON"])WL";

const char* insert_script_template = R"WL(tungstenSelector = ImportString[__SELECTOR__, "RawJSON"];
tungstenCodes = ImportString[__CODES__, "RawJSON"];
tungstenNotebookPath = __NOTEBOOK_PATH__;
tungstenSaveNotebook = __SAVE__;

__HELPERS__

tungstenResult = Module[
    {sourceNotebook, sourceCell, insertionPoint, inserted = {}, code, uuid, insertedCell},
    sourceNotebook = tungstenResolveNotebook @ tungstenNotebookPath;
    If[AssociationQ @ sourceNotebook, sourceNotebook,
        sourceCell = tungstenResolveCell[sourceNotebook, tungstenSelector];
        If[AssociationQ @ sourceCell, sourceCell,
            insertionPoint = sourceCell;
            Do[
                uuid = CreateUUID[];
                SelectionMove[insertionPoint, After, Cell, AutoScroll -> False];
                NotebookWrite[sourceNotebook, Cell[code, "Input", ExpressionUUID -> uuid],
                    All, AutoScroll -> False];
                insertedCell = Quiet @ Check[
                    First[Cells[sourceNotebook, ExpressionUUID -> uuid]], None];
                If[MatchQ[insertedCell, _CellObject], insertionPoint = insertedCell];
                AppendTo[inserted, <|"expression_uuid" -> uuid,
                    "cell_id" -> Replace[If[MatchQ[insertedCell, _CellObject],
                        CurrentValue[insertedCell, CellID], Null],
                        {value_Integer :> value, _ :> Null}], "code" -> code|>],
                {code, tungstenCodes}
            ];
            If[TrueQ @ tungstenSaveNotebook, NotebookSave @ sourceNotebook];
            <|"success" -> True, "source_cell" -> tungstenCellMetadata @ sourceCell,
              "inserted" -> inserted, "saved_notebook" -> TrueQ @ tungstenSaveNotebook|>
        ]
    ]
];
ExportString[tungstenResult, "RawJSON"])WL";

const char* prepare_inline_script_template = R"WL(Needs["Wolfram`Chatbook`" -> None];
tungstenSelector = ImportString[__SELECTOR__, "RawJSON"];
tungstenNotebookPath = __NOTEBOOK_PATH__;
tungstenShowNotebookAssistance = Symbol["Wolfram`Chatbook`ShowNotebookAssistance"];
tungstenCellToString = Symbol["Wolfram`Chatbook`CellToString"];

__HELPERS__

tungstenResult = Module[{sourceNotebook, sourceCell, attachedCell},
    sourceNotebook = tungstenResolveNotebook @ tungstenNotebookPath;
    If[AssociationQ @ sourceNotebook, sourceNotebook,
        SetSelectedNotebook @ sourceNotebook;
        sourceCell = tungstenResolveCell[sourceNotebook, tungstenSelector];
        If[AssociationQ @ sourceCell, sourceCell,
            SelectionMove[sourceCell, All, Cell, AutoScroll -> True];
            attachedCell = Quiet @ Check[tungstenShowNotebookAssistance[
                sourceCell, "Inline", EvaluateInput -> False], $Failed];
            If[!MatchQ[attachedCell, _CellObject],
                tungstenError["InlineAssistantOpenFailed",
                    "Notebook Assistant inline input was not created."],
                SelectionMove[attachedCell, Before, Cell, AutoScroll -> True];
                FrontEnd`MoveCursorToInputField[sourceNotebook, "AttachedChatInputField"];
                <|"success" -> True, "notebook_path" -> tungstenNotebookPath,
                  "window_title" -> Replace[Quiet @ Check[
                    CurrentValue[sourceNotebook, WindowTitle], None],
                    {s_String :> s, _ :> Null}],
                  "source_cell" -> tungstenCellMetadata @ sourceCell,
                  "inline_cell_style" -> tungstenStringValue @ CurrentValue[attachedCell, CellStyle]|>
            ]
        ]
    ]
];
ExportString[tungstenResult, "RawJSON"])WL";

const char* capture_inline_script_template = R"WL(Needs["Wolfram`Chatbook`" -> None];
tungstenSelector = ImportString[__SELECTOR__, "RawJSON"];
tungstenNotebookPath = __NOTEBOOK_PATH__;
tungstenInsertMode = __MODE__;
tungstenSaveNotebook = __SAVE__;
tungstenCellToString = Symbol["Wolfram`Chatbook`CellToString"];
tungstenGetCodeBlockContent = Symbol["Wolfram`Chatbook`Formatting`Private`getCodeBlockContent"];
tungstenInsertAfterChatGeneratedCells = Symbol["Wolfram`Chatbook`Formatting`Private`insertAfterChatGeneratedCells"];

__HELPERS__

tungstenFindInlineCell[nbo_NotebookObject, source_CellObject] := Module[{attached, marker},
    attached = Cells[source, AttachedCell -> True, CellStyle -> "AttachedChatInput"];
    If[attached === {}, attached = Cells[nbo, AttachedCell -> True,
        CellStyle -> "AttachedChatInput"]];
    If[attached === {}, Return[None]];
    marker = ToString[source, InputForm, PageWidth -> Infinity];
    SelectFirst[attached, Quiet @ Check[StringContainsQ[
        ToString[NotebookRead[#], InputForm, PageWidth -> Infinity], marker], False] &,
        First[attached]]
];
tungstenCodeCellData[cell_Cell] := Module[{content, language},
    content = tungstenGetCodeBlockContent @ cell;
    language = Which[
        MatchQ[content, Cell[_, "Input", ___]], "WolframLanguage",
        MatchQ[content, Cell[_, "ExternalLanguage", ___,
            CellEvaluationLanguage -> lang_, ___]],
            "ExternalLanguage:" <> ToString[lang, InputForm, PageWidth -> Infinity],
        True, "Unknown"
    ];
    <|"language" -> language,
      "code" -> Quiet @ Check[tungstenCellToString @ content,
        ToString[content, InputForm, PageWidth -> Infinity]],
      "cell_expression" -> ToString[content, InputForm, PageWidth -> Infinity],
      "insertable" -> MatchQ[content, Cell[_, "Input", ___]], "cell" -> content|>
];
tungstenCodeBlocksFromExpression[expr_] := Module[{rawBlocks},
    rawBlocks = Cases[expr, block : Cell[_, "ChatCodeBlock", ___] :> block, Infinity];
    tungstenCodeCellData /@ rawBlocks
];
tungstenInsertBlocks[source_CellObject, blocks_List, mode_String] := Module[
    {selected, inserted = {}, targetNotebook, insertionPoint, blockData, uuid, prepared, insertedCell},
    selected = Switch[mode, "all", blocks, "first", Take[blocks, UpTo[1]], _, {}];
    If[selected === {}, Return[inserted]];
    targetNotebook = ParentNotebook @ source; insertionPoint = source;
    Do[
        uuid = CreateUUID[];
        prepared = Replace[blockData["cell"], Cell[a___] :> Cell[a, ExpressionUUID -> uuid]];
        tungstenInsertAfterChatGeneratedCells[insertionPoint, prepared];
        insertedCell = Quiet @ Check[
            First[Cells[targetNotebook, ExpressionUUID -> uuid]], None];
        If[MatchQ[insertedCell, _CellObject], insertionPoint = insertedCell];
        AppendTo[inserted, <|"expression_uuid" -> uuid,
            "cell_id" -> Replace[If[MatchQ[insertedCell, _CellObject],
                CurrentValue[insertedCell, CellID], Null],
                {value_Integer :> value, _ :> Null}], "code" -> blockData["code"]|>],
        {blockData, selected}
    ];
    inserted
];

tungstenResult = Module[{sourceNotebook, sourceCell, attachedCell, attachedExpr,
    inputString, outputCells, responseText, allCodeBlockData, wlCodeBlocks,
    inserted, hasProgress, completed},
    sourceNotebook = tungstenResolveNotebook @ tungstenNotebookPath;
    If[AssociationQ @ sourceNotebook, sourceNotebook,
        sourceCell = tungstenResolveCell[sourceNotebook, tungstenSelector];
        If[AssociationQ @ sourceCell, sourceCell,
            attachedCell = tungstenFindInlineCell[sourceNotebook, sourceCell];
            If[!MatchQ[attachedCell, _CellObject],
                tungstenError["InlineAssistantNotFound",
                    "No inline Notebook Assistant input is currently attached to the requested source cell."],
                attachedExpr = Quiet @ Check[NotebookRead @ attachedCell, $Failed];
                inputString = Quiet @ Check[
                    CurrentValue[attachedCell, {TaggingRules, "ChatInputString"}], ""];
                outputCells = Cases[attachedExpr,
                    cell : Cell[_, "ChatOutput", ___] :> cell, Infinity];
                responseText = StringRiffle[Cases[outputCells,
                    cell_Cell :> Quiet @ Check[tungstenCellToString @ cell, ""]], "\n\n"];
                allCodeBlockData = tungstenCodeBlocksFromExpression @ attachedExpr;
                wlCodeBlocks = Select[allCodeBlockData, TrueQ @ #["insertable"] &];
                hasProgress = !FreeQ[attachedExpr,
                    _ProgressIndicator | _ProgressIndicatorBox, Infinity];
                completed = StringQ[inputString] && inputString == ""
                    && Length[outputCells] > 0 && !hasProgress;
                inserted = If[completed && tungstenInsertMode =!= "none",
                    tungstenInsertBlocks[sourceCell, wlCodeBlocks, tungstenInsertMode], {}];
                If[TrueQ @ tungstenSaveNotebook && inserted =!= {}, NotebookSave @ sourceNotebook];
                <|"success" -> True, "completed" -> completed,
                  "has_progress_indicator" -> hasProgress, "inline_attached" -> True,
                  "notebook_path" -> tungstenNotebookPath,
                  "window_title" -> Replace[Quiet @ Check[
                    CurrentValue[sourceNotebook, WindowTitle], None],
                    {s_String :> s, _ :> Null}],
                  "source_cell" -> tungstenCellMetadata @ sourceCell,
                  "input_string" -> tungstenStringValue @ inputString,
                  "response_text" -> responseText,
                  "assistant_output_count" -> Length[outputCells],
                  "code_blocks" -> MapIndexed[
                    Append[KeyDrop[#, "cell"], "index" -> First[#2]] &, allCodeBlockData],
                  "wolfram_code_blocks" -> MapIndexed[
                    Append[KeyDrop[#, "cell"], "index" -> First[#2]] &, wlCodeBlocks],
                  "insert_mode" -> tungstenInsertMode, "inserted" -> inserted,
                  "saved_notebook" -> TrueQ @ tungstenSaveNotebook && inserted =!= {}|>
            ]
        ]
    ]
];
ExportString[tungstenResult, "RawJSON"])WL";

void replace_all(std::string& value, const std::string& marker,
    const std::string& replacement) {
    std::size_t position = 0;
    while ((position = value.find(marker, position)) != std::string::npos) {
        value.replace(position, marker.size(), replacement);
        position += replacement.size();
    }
}

struct Utf8Character {
    std::uint32_t value;
    std::size_t length;
};

Utf8Character decode_utf8_character(
    const std::string& value, std::size_t position) noexcept {
    const auto lead = static_cast<unsigned char>(value[position]);
    if (lead < 0x80) return {lead, 1};
    std::size_t length = 0;
    std::uint32_t codepoint = 0;
    std::uint32_t minimum = 0;
    if (lead >= 0xc2 && lead <= 0xdf) {
        length = 2; codepoint = lead & 0x1f; minimum = 0x80;
    } else if (lead >= 0xe0 && lead <= 0xef) {
        length = 3; codepoint = lead & 0x0f; minimum = 0x800;
    } else if (lead >= 0xf0 && lead <= 0xf4) {
        length = 4; codepoint = lead & 0x07; minimum = 0x10000;
    } else {
        return {lead, 1};
    }
    if (position + length > value.size()) return {lead, 1};
    for (std::size_t index = 1; index < length; ++index) {
        const auto continuation = static_cast<unsigned char>(value[position + index]);
        if ((continuation & 0xc0) != 0x80) return {lead, 1};
        codepoint = (codepoint << 6) | (continuation & 0x3f);
    }
    if (codepoint < minimum || codepoint > 0x10ffff
        || (codepoint >= 0xd800 && codepoint <= 0xdfff)) return {lead, 1};
    return {codepoint, length};
}

bool python_whitespace(std::uint32_t value) noexcept {
    return (value >= 0x09 && value <= 0x0d)
        || (value >= 0x1c && value <= 0x20)
        || value == 0x85 || value == 0xa0 || value == 0x1680
        || (value >= 0x2000 && value <= 0x200a)
        || value == 0x2028 || value == 0x2029 || value == 0x202f
        || value == 0x205f || value == 0x3000;
}

std::string trim_copy(const std::string& value) {
    std::size_t begin = 0;
    while (begin < value.size()) {
        const auto character = decode_utf8_character(value, begin);
        if (!python_whitespace(character.value)) break;
        begin += character.length;
    }
    std::size_t position = begin;
    std::size_t last_non_space = begin;
    while (position < value.size()) {
        const auto character = decode_utf8_character(value, position);
        position += character.length;
        if (!python_whitespace(character.value)) last_non_space = position;
    }
    return value.substr(begin, last_non_space - begin);
}

std::string collapse_python_whitespace(const std::string& value) {
    const auto trimmed = trim_copy(value);
    std::string output;
    bool pending_space = false;
    for (std::size_t position = 0; position < trimmed.size();) {
        const auto character = decode_utf8_character(trimmed, position);
        if (python_whitespace(character.value)) {
            pending_space = !output.empty();
        } else {
            if (pending_space) output.push_back(' ');
            pending_space = false;
            output.append(trimmed, position, character.length);
        }
        position += character.length;
    }
    return output;
}

std::string lowercase_ascii(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char character) {
        return detail::ascii_lower(character);
    });
    return value;
}

JsonValue string_array(const std::vector<std::string>& values) {
    JsonValue::Array output;
    output.reserve(values.size());
    for (const auto& value : values) output.emplace_back(value);
    return output;
}

JsonValue json_array(const std::vector<JsonValue>& values) {
    return JsonValue::Array(values.begin(), values.end());
}

bool payload_success(const JsonValue& payload) noexcept {
    const auto* success = payload.find("success");
    return success != nullptr && success->is_boolean() && success->as_boolean();
}

JsonValue failure(const std::string& type, const std::string& message) {
    return JsonValue::object({
        {"success", false}, {"error_type", type}, {"error", message}});
}

std::string absolute_slash_path(const fs::path& path) {
    std::error_code error;
    auto absolute = path.is_absolute() ? path : fs::absolute(path, error);
    if (error) absolute = path;
    return absolute.lexically_normal().generic_u8string();
}

std::string helper_block(
    const std::string& preview_expression,
    const std::vector<std::string>& extra_clear_names = {}) {
    auto result = std::string(assistant_helpers_template);
    std::string extra;
    for (const auto& name : extra_clear_names) extra += ",\n    " + name;
    replace_all(result, "__EXTRA_CLEAR__", extra);
    replace_all(result, "__PREVIEW__", preview_expression);
    return result;
}

JsonValue assistant_settings(
    const std::optional<std::string>& service,
    const std::optional<std::string>& name,
    const std::optional<std::vector<std::string>>& tools = std::nullopt) {
    JsonValue::Object settings{
        {"AutoSaveConversations", false},
        {"Tools", string_array(tools.value_or(default_tools))},
    };
    if (service || name) {
        settings["Model"] = JsonValue::object({
            {"Service", service.value_or("Automatic")},
            {"Name", name.value_or("Automatic")},
        });
    }
    return settings;
}

std::vector<JsonValue> insertable_blocks(const std::vector<JsonValue>& blocks) {
    std::vector<JsonValue> result;
    for (const auto& block : blocks) {
        const auto* value = block.find("insertable");
        if (value != nullptr && value->is_boolean() && value->as_boolean())
            result.push_back(block);
    }
    return result;
}

void append_utf8(std::string& output, std::uint32_t value) {
    if (value <= 0x7f) output.push_back(static_cast<char>(value));
    else if (value <= 0x7ff) {
        output.push_back(static_cast<char>(0xc0 | (value >> 6)));
        output.push_back(static_cast<char>(0x80 | (value & 0x3f)));
    } else if (value <= 0xffff) {
        output.push_back(static_cast<char>(0xe0 | (value >> 12)));
        output.push_back(static_cast<char>(0x80 | ((value >> 6) & 0x3f)));
        output.push_back(static_cast<char>(0x80 | (value & 0x3f)));
    } else if (value <= 0x10ffff) {
        output.push_back(static_cast<char>(0xf0 | (value >> 18)));
        output.push_back(static_cast<char>(0x80 | ((value >> 12) & 0x3f)));
        output.push_back(static_cast<char>(0x80 | ((value >> 6) & 0x3f)));
        output.push_back(static_cast<char>(0x80 | (value & 0x3f)));
    }
}

std::optional<std::uint32_t> hex_value(
    const std::string& value, std::size_t position, std::size_t digits) {
    if (position + digits > value.size()) return std::nullopt;
    std::uint32_t result = 0;
    for (std::size_t index = 0; index < digits; ++index) {
        const unsigned char character = static_cast<unsigned char>(value[position + index]);
        result <<= 4;
        if (character >= '0' && character <= '9') result |= character - '0';
        else if (character >= 'a' && character <= 'f') result |= character - 'a' + 10;
        else if (character >= 'A' && character <= 'F') result |= character - 'A' + 10;
        else return std::nullopt;
    }
    return result;
}

std::string decode_backslash_escapes(const std::string& value) {
    std::string output;
    for (std::size_t index = 0; index < value.size(); ++index) {
        if (value[index] != '\\' || index + 1 >= value.size()) {
            output.push_back(value[index]);
            continue;
        }
        const char escaped = value[++index];
        switch (escaped) {
        case 'n': output.push_back('\n'); break;
        case 'r': output.push_back('\r'); break;
        case 't': output.push_back('\t'); break;
        case 'b': output.push_back('\b'); break;
        case 'f': output.push_back('\f'); break;
        case '"': output.push_back('"'); break;
        case '\\': output.push_back('\\'); break;
        case '/': output.push_back('/'); break;
        case 'x': {
            const auto decoded = hex_value(value, index + 1, 2);
            if (decoded) {
                append_utf8(output, *decoded);
                index += 2;
            } else output += "\\x";
            break;
        }
        case 'u': {
            const auto decoded = hex_value(value, index + 1, 4);
            if (decoded) {
                append_utf8(output, *decoded);
                index += 4;
            } else output += "\\u";
            break;
        }
        default:
            output.push_back('\\');
            output.push_back(escaped);
            break;
        }
    }
    return output;
}

std::string decode_chat_string(const std::string& value) {
    std::string decoded = value;
    try {
        const auto parsed = JsonValue::parse('"' + value + '"');
        if (parsed.is_string()) decoded = parsed.as_string();
    } catch (const std::exception&) {
    }
    if (decoded.find("\\n") != std::string::npos
        || decoded.find("\\t") != std::string::npos
        || decoded.find("\\\"") != std::string::npos
        || decoded.find("\\\\") != std::string::npos)
        return decode_backslash_escapes(decoded);
    return decoded;
}

void skip_pattern_space(const std::string& value, std::size_t& position) noexcept {
    while (position < value.size()
        && detail::ascii_is_space(static_cast<unsigned char>(value[position]))) ++position;
}

bool consume_pattern_token(
    const std::string& value, std::size_t& position, const std::string& token) {
    if (position > value.size() || token.size() > value.size() - position
        || value.compare(position, token.size(), token) != 0) return false;
    position += token.size();
    return true;
}

std::optional<std::pair<std::string, std::size_t>> next_assistant_section(
    const std::string& value, std::size_t search_from) {
    constexpr const char* role_marker = R"(<|"Role")";
    while (true) {
        const auto marker = value.find(role_marker, search_from);
        if (marker == std::string::npos) return std::nullopt;
        auto position = marker + std::char_traits<char>::length(role_marker);
        skip_pattern_space(value, position);
        if (!consume_pattern_token(value, position, "->")) {
            search_from = marker + 1;
            continue;
        }
        skip_pattern_space(value, position);
        if (!consume_pattern_token(value, position, R"("Assistant")")) {
            search_from = marker + 1;
            continue;
        }
        const auto content_marker = value.find(R"("Content")", position);
        if (content_marker == std::string::npos) return std::nullopt;
        position = content_marker + std::char_traits<char>::length(R"("Content")");
        skip_pattern_space(value, position);
        if (!consume_pattern_token(value, position, "->")) {
            search_from = marker + 1;
            continue;
        }
        skip_pattern_space(value, position);
        if (!consume_pattern_token(value, position, "{")) {
            search_from = marker + 1;
            continue;
        }
        const auto section_start = position;
        auto close = value.find('}', section_start);
        while (close != std::string::npos) {
            auto after = close + 1;
            skip_pattern_space(value, after);
            if (!consume_pattern_token(value, after, ",")) {
                close = value.find('}', close + 1);
                continue;
            }
            skip_pattern_space(value, after);
            if (!consume_pattern_token(value, after, R"("Metadata")")) {
                close = value.find('}', close + 1);
                continue;
            }
            skip_pattern_space(value, after);
            if (!consume_pattern_token(value, after, "->")) {
                close = value.find('}', close + 1);
                continue;
            }
            return std::pair<std::string, std::size_t>{
                value.substr(section_start, close - section_start), after};
        }
        search_from = marker + 1;
    }
}

std::vector<std::string> assistant_text_chunks(const std::string& section) {
    std::vector<std::string> chunks;
    std::size_t search_from = 0;
    constexpr const char* type_marker = R"("Type")";
    while (true) {
        const auto marker = section.find(type_marker, search_from);
        if (marker == std::string::npos) break;
        auto position = marker + std::char_traits<char>::length(type_marker);
        skip_pattern_space(section, position);
        if (!consume_pattern_token(section, position, "->")) {
            search_from = marker + 1;
            continue;
        }
        skip_pattern_space(section, position);
        if (!consume_pattern_token(section, position, R"("Text")")) {
            search_from = marker + 1;
            continue;
        }
        skip_pattern_space(section, position);
        if (!consume_pattern_token(section, position, ",")) {
            search_from = marker + 1;
            continue;
        }
        skip_pattern_space(section, position);
        if (!consume_pattern_token(section, position, R"("Data")")) {
            search_from = marker + 1;
            continue;
        }
        skip_pattern_space(section, position);
        if (!consume_pattern_token(section, position, "->")) {
            search_from = marker + 1;
            continue;
        }
        skip_pattern_space(section, position);
        if (!consume_pattern_token(section, position, "\"")) {
            search_from = marker + 1;
            continue;
        }
        const auto close = section.find('"', position);
        if (close == std::string::npos) break;
        auto decoded = decode_chat_string(section.substr(position, close - position));
        if (!decoded.empty()) chunks.push_back(std::move(decoded));
        search_from = close + 1;
    }
    return chunks;
}

NotebookDocument load_assistant_document(const fs::path& path) {
    try {
        return NotebookDocument::load(path);
    } catch (const NotebookError& error) {
        throw AssistantError(AssistantErrorCode::Notebook, error.what());
    } catch (const fs::filesystem_error& error) {
        throw AssistantError(AssistantErrorCode::Notebook, error.what());
    }
}

} // namespace

AssistantError::AssistantError(AssistantErrorCode code, std::string message)
    : std::runtime_error(std::move(message)), code_(code) {}

AssistantErrorCode AssistantError::code() const noexcept { return code_; }

bool NotebookAssistantResult::assistant_success() const noexcept {
    return payload_success(payload);
}

JsonValue NotebookAssistantResult::to_json() const {
    return JsonValue::object({
        {"assistant_success", assistant_success()},
        {"assistant", payload},
        {"evaluation", evaluation.to_json()},
    });
}

std::string assistant_insert_mode(bool first, bool all) {
    if (all) return "all";
    if (first) return "first";
    return "none";
}

NotebookRow resolve_assistant_row(
    const NotebookDocument& document, const AssistantCellSelector& selector) {
    try {
        return std::visit([&](const auto& selected) -> NotebookRow {
            using Selected = std::decay_t<decltype(selected)>;
            if constexpr (std::is_same_v<Selected, AssistantFlatIndexSelector>) {
                return document.cell_at_flat_index(selected.index);
            } else if constexpr (std::is_same_v<Selected, AssistantPathSelector>) {
                return document.cell_at_path(selected.path);
            } else {
                const auto rows = document.flattened_cells();
                std::vector<NotebookRow> matches;
                for (const auto& row : rows) {
                    bool match = false;
                    if constexpr (std::is_same_v<Selected,
                                      AssistantExpressionUuidSelector>)
                        match = row.expression_uuid == selected.value;
                    else if constexpr (std::is_same_v<Selected,
                                           AssistantCellIdSelector>)
                        match = row.cell_id == selected.value;
                    else if constexpr (std::is_same_v<Selected,
                                           AssistantCellTagSelector>)
                        match = std::find(row.cell_tags.begin(), row.cell_tags.end(),
                                    selected.value) != row.cell_tags.end();
                    if (match) matches.push_back(row);
                }
                if (matches.size() == 1) return matches.front();
                if (matches.empty())
                    throw AssistantError(AssistantErrorCode::InvalidSelector,
                        "The requested notebook cell selector did not match any cell "
                        "in the notebook file.");
                throw AssistantError(AssistantErrorCode::InvalidSelector,
                    "The requested notebook cell selector matched more than one cell "
                    "in the notebook file.");
            }
        }, selector);
    } catch (const AssistantError&) {
        throw;
    } catch (const NotebookError& error) {
        throw AssistantError(AssistantErrorCode::Notebook, error.what());
    }
}

JsonValue assistant_selector_from_row(const NotebookRow& row) {
    if (row.expression_uuid && !row.expression_uuid->empty())
        return JsonValue::object({{"expression_uuid", *row.expression_uuid}});
    if (row.cell_id)
        return JsonValue::object({{"cell_id", static_cast<long long>(*row.cell_id)}});
    if (!row.cell_tags.empty() && !row.cell_tags.front().empty())
        return JsonValue::object({{"cell_tag", row.cell_tags.front()}});
    return JsonValue::object({{"cell_index", static_cast<unsigned long long>(row.index)}});
}

JsonValue assistant_selector_for_kernel(
    const NotebookRow& row, const AssistantCellSelector& requested) {
    return std::visit([&](const auto& selected) -> JsonValue {
        using Selected = std::decay_t<decltype(selected)>;
        if constexpr (std::is_same_v<Selected, AssistantExpressionUuidSelector>)
            return JsonValue::object({{"expression_uuid", selected.value}});
        else if constexpr (std::is_same_v<Selected, AssistantCellIdSelector>)
            return JsonValue::object(
                {{"cell_id", static_cast<long long>(selected.value)}});
        else if constexpr (std::is_same_v<Selected, AssistantCellTagSelector>)
            return JsonValue::object({{"cell_tag", selected.value}});
        else
            return assistant_selector_from_row(row);
    }, requested);
}

JsonValue parse_assistant_payload(const KernelEvaluationResult& evaluation) {
    if (!evaluation.evaluation_available) {
        return failure("EvaluationUnavailable",
            evaluation.stderr_text.empty()
                ? "The Wolfram evaluation did not produce a structured payload."
                : evaluation.stderr_text);
    }
    if (evaluation.success == false) {
        const auto type = evaluation.failure_type.value_or("KernelEvaluationFailure");
        std::string message = evaluation.stderr_text;
        if (message.empty() && evaluation.result) message = *evaluation.result;
        if (message.empty()) message = "The Wolfram evaluation failed.";
        return failure(type, message);
    }
    if (!evaluation.result || evaluation.result->empty()) {
        return failure("MissingAssistantPayload",
            "The Wolfram evaluation completed but did not return an assistant payload.");
    }

    try {
        const auto payload_text = parse_wl_string_literal(*evaluation.result);
        auto payload = JsonValue::parse(payload_text);
        if (payload.is_object()) return payload;
        return JsonValue::object({
            {"success", false},
            {"error_type", "InvalidAssistantPayload"},
            {"error", "The assistant payload was not a JSON object."},
            {"raw_payload", std::move(payload)},
        });
    } catch (const std::exception& error) {
        return JsonValue::object({
            {"success", false},
            {"error_type", "InvalidAssistantPayload"},
            {"error", std::string("Unable to parse assistant payload JSON: ")
                + error.what()},
            {"raw_result", *evaluation.result},
        });
    }
}

std::string extract_assistant_text(const std::string& chat_object_string) {
    std::string section;
    std::size_t search_from = 0;
    while (const auto match = next_assistant_section(chat_object_string, search_from)) {
        section = match->first;
        search_from = match->second;
    }
    if (section.empty()) return {};
    const auto chunks = assistant_text_chunks(section);
    std::string result;
    for (const auto& chunk : chunks) {
        if (!result.empty()) result += "\n\n";
        result += chunk;
    }
    return result;
}

std::vector<JsonValue> extract_assistant_code_blocks(
    const std::string& response_text) {
    std::vector<JsonValue> blocks;
    std::size_t index = 0;
    std::size_t search_from = 0;
    while (true) {
        const auto opening = response_text.find("```", search_from);
        if (opening == std::string::npos) break;
        const auto language_start = opening + 3;
        const auto newline = response_text.find('\n', language_start);
        const auto backtick = response_text.find('`', language_start);
        if (newline == std::string::npos
            || (backtick != std::string::npos && backtick < newline)) {
            search_from = opening + 1;
            continue;
        }
        const auto close = response_text.find("```", newline + 1);
        if (close == std::string::npos) break;
        const auto language = trim_copy(
            response_text.substr(language_start, newline - language_start));
        const auto normalized = lowercase_ascii(collapse_python_whitespace(language));
        const bool insertable = normalized == "wolfram"
            || normalized == "wolfram language" || normalized == "wolframlanguage"
            || normalized == "mathematica" || normalized == "wl";
        blocks.push_back(JsonValue::object({
            {"index", static_cast<unsigned long long>(index)},
            {"language", language.empty() ? "Unknown" : language},
            {"code", trim_copy(response_text.substr(newline + 1, close - newline - 1))},
            {"insertable", insertable},
        }));
        ++index;
        search_from = close + 3;
    }
    return blocks;
}

JsonValue finalize_assistant_ask_payload(JsonValue payload) {
    if (!payload_success(payload)) return payload;
    const auto* chat = payload.find("assistant_chat_object_string");
    if (chat == nullptr || !chat->is_string() || chat->as_string().empty()) {
        return failure("AssistantResponseUnavailable",
            "Notebook Assistant did not return a chat object string that Tungsten "
            "could inspect.");
    }
    const auto response = extract_assistant_text(chat->as_string());
    if (response.empty()) {
        return JsonValue::object({
            {"success", false},
            {"error_type", "AssistantResponseUnavailable"},
            {"error", "Notebook Assistant completed, but Tungsten could not extract "
                      "an assistant text response."},
            {"assistant_chat_object_string", chat->as_string()},
        });
    }
    const auto blocks = extract_assistant_code_blocks(response);
    const auto wolfram = insertable_blocks(blocks);
    auto enriched = payload.as_object();
    enriched.erase("assistant_chat_object_string");
    enriched["response_text"] = response;
    enriched["code_blocks"] = json_array(blocks);
    enriched["wolfram_code_blocks"] = json_array(wolfram);
    return enriched;
}

std::string build_assistant_ask_script(const AskOptions& options) {
    auto script = std::string(ask_script_template);
    replace_all(script, "__SETTINGS__", wl_string(assistant_settings(
        options.model_service, options.model_name, options.tools).dump()));
    replace_all(script, "__PROMPT__", wl_string(options.prompt));
    replace_all(script, "__SYSTEM_PROMPT__",
        wl_string(trim_copy(options.system_prompt.value_or(""))));
    replace_all(script, "__EXTRA_INSTRUCTIONS__",
        wl_string(trim_copy(options.extra_instructions.value_or(""))));
    return script;
}

std::string build_assistant_ask_cell_script(
    const AskCellOptions& options, const JsonValue& selector) {
    auto script = std::string(ask_cell_script_template);
    replace_all(script, "__SELECTOR__", wl_string(selector.dump()));
    replace_all(script, "__SETTINGS__", wl_string(assistant_settings(
        options.model_service, options.model_name).dump()));
    replace_all(script, "__QUESTION__", wl_string(options.question));
    replace_all(script, "__NOTEBOOK_PATH__",
        wl_string(absolute_slash_path(options.notebook_path)));
    auto instructions = std::string(default_instructions);
    if (options.extra_instructions && !options.extra_instructions->empty())
        instructions += "\n\n" + *options.extra_instructions;
    replace_all(script, "__INSTRUCTIONS__", wl_string(instructions));
    replace_all(script, "__HELPERS__", helper_block(
        "tungstenCellToString @ cellExpr",
        {"tungstenPromptCell", "tungstenChatSettings"}));
    return script;
}

std::string build_assistant_insert_script(
    const fs::path& notebook_path, const JsonValue& selector,
    const std::vector<std::string>& code_strings, bool save_notebook) {
    auto script = std::string(insert_script_template);
    replace_all(script, "__SELECTOR__", wl_string(selector.dump()));
    replace_all(script, "__CODES__", wl_string(string_array(code_strings).dump()));
    replace_all(script, "__NOTEBOOK_PATH__",
        wl_string(absolute_slash_path(notebook_path)));
    replace_all(script, "__SAVE__", save_notebook ? "True" : "False");
    replace_all(script, "__HELPERS__",
        helper_block("ToString[cellExpr, InputForm, PageWidth -> Infinity]"));
    return script;
}

std::string build_assistant_prepare_inline_script(
    const fs::path& notebook_path, const JsonValue& selector) {
    auto script = std::string(prepare_inline_script_template);
    replace_all(script, "__SELECTOR__", wl_string(selector.dump()));
    replace_all(script, "__NOTEBOOK_PATH__",
        wl_string(absolute_slash_path(notebook_path)));
    replace_all(script, "__HELPERS__",
        helper_block("tungstenCellToString @ cellExpr"));
    return script;
}

std::string build_assistant_capture_inline_script(
    const fs::path& notebook_path, const JsonValue& selector,
    const std::string& insert_mode, bool save_notebook) {
    auto script = std::string(capture_inline_script_template);
    replace_all(script, "__SELECTOR__", wl_string(selector.dump()));
    replace_all(script, "__NOTEBOOK_PATH__",
        wl_string(absolute_slash_path(notebook_path)));
    replace_all(script, "__MODE__", wl_string(insert_mode));
    replace_all(script, "__SAVE__", save_notebook ? "True" : "False");
    replace_all(script, "__HELPERS__", helper_block(
        "tungstenCellToString @ cellExpr",
        {"tungstenFindInlineCell", "tungstenCodeCellData",
            "tungstenCodeBlocksFromExpression", "tungstenInsertBlocks"}));
    return script;
}

NotebookAssistantController::NotebookAssistantController()
    : runner_(WolframKernelRunner()) {}

NotebookAssistantController::NotebookAssistantController(
    WolframKernelRunner runner)
    : runner_(std::move(runner)) {}

NotebookAssistantController::NotebookAssistantController(
    AssistantEvaluationFunction evaluator)
    : evaluator_(std::move(evaluator)) {
    if (!evaluator_)
        throw AssistantError(AssistantErrorCode::Kernel,
            "assistant evaluation callback must not be empty");
}

NotebookAssistantController::NotebookAssistantController(
    WolframKernelRunner runner, AssistantEvaluationFunction evaluator)
    : runner_(std::move(runner)), evaluator_(std::move(evaluator)) {}

const WolframKernelRunner* NotebookAssistantController::runner() const noexcept {
    return runner_ ? &*runner_ : nullptr;
}

KernelEvaluationResult NotebookAssistantController::evaluate(
    const std::string& script) const {
    KernelEvaluationOptions options;
    options.require_front_end = true;
    try {
        if (evaluator_) return evaluator_(script, options);
        if (runner_) return runner_->evaluate_text(script, options);
    } catch (const KernelError& error) {
        throw AssistantError(AssistantErrorCode::Kernel, error.what());
    }
    throw AssistantError(
        AssistantErrorCode::Kernel, "no assistant evaluation backend is available");
}

NotebookAssistantResult NotebookAssistantController::ask(
    const AskOptions& options) const {
    auto evaluation = evaluate(build_assistant_ask_script(options));
    auto payload = finalize_assistant_ask_payload(parse_assistant_payload(evaluation));
    return {std::move(evaluation), std::move(payload)};
}

NotebookAssistantResult NotebookAssistantController::ask_cell(
    const AskCellOptions& options) const {
    const auto document = load_assistant_document(options.notebook_path);
    const auto row = resolve_assistant_row(document, options.selector);
    const auto selector = assistant_selector_for_kernel(row, options.selector);
    auto evaluation = evaluate(build_assistant_ask_cell_script(options, selector));
    const auto mode = assistant_insert_mode(
        options.insert_wolfram_code, options.insert_all_wolfram_code);
    auto payload = finalize_ask_cell_payload(parse_assistant_payload(evaluation),
        options.notebook_path, row, mode, options.save_notebook);
    return {std::move(evaluation), std::move(payload)};
}

NotebookAssistantResult NotebookAssistantController::prepare_inline(
    const fs::path& notebook_path, const AssistantCellSelector& selector) const {
    const auto document = load_assistant_document(notebook_path);
    const auto row = resolve_assistant_row(document, selector);
    const auto kernel_selector = assistant_selector_for_kernel(row, selector);
    auto evaluation = evaluate(
        build_assistant_prepare_inline_script(notebook_path, kernel_selector));
    auto payload = parse_assistant_payload(evaluation);
    return {std::move(evaluation), std::move(payload)};
}

NotebookAssistantResult NotebookAssistantController::capture_inline(
    const fs::path& notebook_path, const AssistantCellSelector& selector,
    bool insert_wolfram_code, bool insert_all_wolfram_code,
    bool save_notebook) const {
    const auto document = load_assistant_document(notebook_path);
    const auto row = resolve_assistant_row(document, selector);
    const auto kernel_selector = assistant_selector_for_kernel(row, selector);
    auto evaluation = evaluate(build_assistant_capture_inline_script(notebook_path,
        kernel_selector, assistant_insert_mode(
            insert_wolfram_code, insert_all_wolfram_code), save_notebook));
    auto payload = parse_assistant_payload(evaluation);
    return {std::move(evaluation), std::move(payload)};
}

std::string NotebookAssistantController::build_ask_script(
    const AskOptions& options) const {
    return build_assistant_ask_script(options);
}

JsonValue NotebookAssistantController::finalize_ask_payload(JsonValue payload) const {
    return finalize_assistant_ask_payload(std::move(payload));
}

JsonValue NotebookAssistantController::insert_code_blocks(
    const fs::path& notebook_path, const NotebookRow& source_row,
    const std::vector<JsonValue>& blocks, const std::string& insert_mode,
    bool save_notebook) const {
    if (insert_mode == "none" || blocks.empty()) {
        return JsonValue::object({
            {"success", true}, {"inserted", JsonValue::Array{}},
            {"saved_notebook", false}});
    }
    const auto take = insert_mode == "all" ? blocks.size() : std::size_t{1};
    std::vector<std::string> codes;
    for (std::size_t index = 0; index < blocks.size() && index < take; ++index) {
        const auto* code = blocks[index].find("code");
        if (code != nullptr && code->is_string() && !code->as_string().empty())
            codes.push_back(code->as_string());
    }
    if (codes.empty()) {
        return JsonValue::object({
            {"success", true}, {"inserted", JsonValue::Array{}},
            {"saved_notebook", false}});
    }
    const auto selector = assistant_selector_from_row(source_row);
    auto evaluation = evaluate(build_assistant_insert_script(
        notebook_path, selector, codes, save_notebook));
    auto payload = parse_assistant_payload(evaluation);
    if (!payload_success(payload)) return payload;
    const auto* inserted = payload.find("inserted");
    const auto* saved = payload.find("saved_notebook");
    return JsonValue::object({
        {"success", true},
        {"inserted", inserted == nullptr ? JsonValue::Array{} : *inserted},
        {"saved_notebook", saved != nullptr && saved->is_boolean()
            && saved->as_boolean()},
    });
}

JsonValue NotebookAssistantController::finalize_ask_cell_payload(
    JsonValue payload, const fs::path& notebook_path,
    const NotebookRow& source_row, const std::string& insert_mode,
    bool save_notebook) const {
    if (!payload_success(payload)) return payload;
    const auto* source = payload.find("source_cell");
    const auto source_cell = source == nullptr ? JsonValue(nullptr) : *source;
    const auto* chat = payload.find("assistant_chat_object_string");
    if (chat == nullptr || !chat->is_string() || chat->as_string().empty()) {
        return JsonValue::object({
            {"success", false}, {"error_type", "AssistantResponseUnavailable"},
            {"error", "Notebook Assistant did not return a chat object string that "
                      "Tungsten could inspect."},
            {"source_cell", source_cell},
        });
    }
    const auto response = extract_assistant_text(chat->as_string());
    if (response.empty()) {
        return JsonValue::object({
            {"success", false}, {"error_type", "AssistantResponseUnavailable"},
            {"error", "Notebook Assistant completed, but Tungsten could not extract "
                      "an assistant text response."},
            {"source_cell", source_cell},
            {"assistant_chat_object_string", chat->as_string()},
        });
    }
    const auto blocks = extract_assistant_code_blocks(response);
    const auto wolfram = insertable_blocks(blocks);
    const auto insertion = insert_code_blocks(
        notebook_path, source_row, wolfram, insert_mode, save_notebook);
    if (!payload_success(insertion)) {
        const auto* type = insertion.find("error_type");
        const auto* error = insertion.find("error");
        return JsonValue::object({
            {"success", false},
            {"error_type", type != nullptr && type->is_string()
                ? JsonValue(type->as_string()) : JsonValue("InsertionFailure")},
            {"error", error != nullptr && error->is_string()
                ? JsonValue(error->as_string())
                : JsonValue("Tungsten could not insert the generated Wolfram code.")},
            {"source_cell", source_cell},
            {"response_text", response},
            {"code_blocks", json_array(blocks)},
            {"wolfram_code_blocks", json_array(wolfram)},
        });
    }
    auto enriched = payload.as_object();
    enriched.erase("assistant_chat_object_string");
    enriched["response_text"] = response;
    enriched["code_blocks"] = json_array(blocks);
    enriched["wolfram_code_blocks"] = json_array(wolfram);
    enriched["insert_mode"] = insert_mode;
    const auto* inserted = insertion.find("inserted");
    enriched["inserted"] = inserted == nullptr ? JsonValue::Array{} : *inserted;
    const auto* saved = insertion.find("saved_notebook");
    enriched["saved_notebook"] = saved != nullptr && saved->is_boolean()
        && saved->as_boolean();
    return enriched;
}

} // namespace tungsten
