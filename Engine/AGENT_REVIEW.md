# Agent Review: `src/Tungsten`

Created (UTC): 2026-04-28T21:25:00Z

## Why this directory matters to Nummy/Gamma

The Nummy `gamma/` prototype ships a tiny calculator REPL whose UX is intentionally similar to
`src/Tungsten`’s `tungsten.exe` console: `In[n]:=` prompts, `Out[n]= ...` outputs, and session
history shorthands like `%` and `%%`.

This file records the key interface details used as reference so future REPL experiments can
stay consistent with Tungsten’s interaction model.

## Key REPL interface conventions (from docs)

From `src/Tungsten/docs/repl.md`:

- Prompt shape:
  - input prompt: `In[n]:=`
  - output label: `Out[n]= ...`
- Session history:
  - `Out[n]` addresses the stored output expression for input line `n`.
  - `Out[]` / `Out[-k]` are relative addressing forms.
  - Parser shorthands:
    - `%` → previous output
    - `%%` → second-to-last output
    - `%n` → output line `n`
- Session values used for history/introspection:
  - `$Line`, `In`, `InString`, `Out`, and read-only `DownValues` synthesized from the active session.

## Observations

- Tungsten’s “Wolfram console” affordances (prompts + `%` history) are load-bearing: they make
  an otherwise minimal interpreter feel scriptable and familiar immediately.
- The docs are unusually explicit about history semantics (including `%` parsing), making them
  a solid spec for other REPLs in this repository to mimic.

## Conclusions

- Any future calculator/REPL prototypes in this repository should strongly consider adopting
  the same `In[n]` / `Out[n]` session-history shape, even if the language surface is unrelated.

