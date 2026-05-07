from __future__ import annotations

from pathlib import Path

from .docs_index import DocumentationIndex
from .kernel import KernelEvaluationResult, WolframKernelRunner
from .notebook import wl_string


class FrontEndController:
    def __init__(
        self,
        runner: WolframKernelRunner | None = None,
        docs_index: DocumentationIndex | None = None,
    ) -> None:
        self.runner = runner or WolframKernelRunner()
        self.docs_index = docs_index or DocumentationIndex(self.runner.installation)

    def probe(self) -> dict[str, object]:
        result = self.runner.evaluate_text(
            'nb = UsingFrontEnd[CreateDocument[Notebook[{Cell["Tungsten probe", "Text"]}, Visible -> False]]];'
            " head = Head[nb];"
            " UsingFrontEnd[NotebookClose[nb]];"
            " head"
        )
        return result.to_dict()

    def run(self, code: str, *, wrap_using_front_end: bool = True) -> KernelEvaluationResult:
        return self.runner.evaluate_text(code, require_front_end=wrap_using_front_end)

    def open_notebook(self, path: Path) -> KernelEvaluationResult:
        return self.runner.evaluate_text(
            f"NotebookOpen[{wl_string(str(path.resolve().as_posix()))}]",
            require_front_end=True,
        )

    def open_documentation(
        self,
        identifier: str,
        *,
        index_path: Path | None = None,
    ) -> KernelEvaluationResult:
        paclet = self.docs_index.resolve_identifier(identifier, index_path=index_path)
        return self.runner.evaluate_text(
            f"NotebookLocate[{wl_string(paclet)}]",
            require_front_end=True,
        )

    def execute_token(
        self,
        token: str,
        *,
        notebook_path: Path | None = None,
    ) -> KernelEvaluationResult:
        if notebook_path is None:
            code = f"FrontEndTokenExecute[{wl_string(token)}]"
        else:
            notebook_literal = wl_string(str(notebook_path.resolve().as_posix()))
            code = (
                f"nb = NotebookOpen[{notebook_literal}];"
                f" FrontEndTokenExecute[nb, {wl_string(token)}];"
                " nb"
            )
        return self.runner.evaluate_text(code, require_front_end=True)
