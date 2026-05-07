from __future__ import annotations


class TungieSyntaxError(ValueError):
    """Raised when Tungie cannot parse supported calculator input."""


class TungieEvaluationError(ValueError):
    """Raised when Tungie cannot evaluate a supported built-in shape."""


class TungieExitRequested(Exception):
    """Raised when evaluation reaches Exit or Exit[n]."""

    def __init__(self, code: int = 0) -> None:
        super().__init__(code)
        self.code = int(code)
