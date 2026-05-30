# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository shape

This is a multi-language polyrepo holding three nested libraries (each implemented three times in Clojure, Python, TypeScript) plus a two-language `bc-pkg` launcher:

```
bigconfig/
├── selmer/{clojure,python,typescript}      # Django-style template engine
├── big-config/{clojure,python,typescript}  # Workflow + render engine (uses selmer)
├── once/{clojure,python,typescript}        # Infra automation CLI (uses big-config)
└── launcher/{python,typescript}            # `bc-pkg` bootstrap launcher (PyPI / npm)
```

Each of the eleven leaves is an independent project with its own build system, tests, and `CLAUDE.md` / `README.md`. **Always read the leaf's `CLAUDE.md` before editing inside it** — the per-language conventions, what-to-avoid lists, and entry-point naming differ.

The root directory itself is not a git repo and has no build system; it's a workspace that holds the projects side-by-side so they can reference each other by relative path during development.

## Dependency direction

```
once  ──depends-on──▶  big-config  ──depends-on──▶  selmer
```

Within a single language, projects consume each other either as published packages or as local-path overrides:

- **Clojure**: `once/clojure/deps.edn` pins `io.github.amiorin/big-config` and has a commented `:local/root "../../big-config/clojure"` line — swap to develop against local source. `big-config/clojure` uses Selmer from Maven (`selmer/selmer 1.13.1`).
- **Python**: `once/python/pyproject.toml` pins `big-config` to a Git commit; `big-config/python/pyproject.toml` pins `selmer` to a Git commit. Use `uv sync` to resolve.
- **TypeScript**: `once/typescript/package.json` pins `big-config` to a GitHub commit; `big-config/typescript/package.json` pins `selmer` to a GitHub commit. There is also reference in some docs to a local path `../../big-config/typescript` — verify which mode is active before assuming.

Cross-language work that touches the engine surface (e.g., adding a step type, a renderer feature, or a workflow primitive) needs the change applied in all three implementations of that library, then re-verified in the consumers downstream.

The `launcher/` projects (`bc-pkg`) are independent of the `selmer → big-config → once` chain: they are bootstrap CLIs that resolve a GitHub-pinned BigConfig package and forward commands to it. They do not import any of the three libraries.

## Per-language commands

Run these inside the relevant leaf directory (e.g., `cd big-config/python && uv run pytest -q`):

| Leaf | Install / sync | Test | Typecheck / build | Run CLI |
|---|---|---|---|---|
| `*/clojure` | (deps auto-resolve) | `clojure -M:test` | — | `bb <task>` (where a `bb.edn` exists) |
| `*/python` | `uv sync` | `uv run pytest -q` | — | `uv run <entry-point>` (e.g., `uv run once`, `uv run big-config`) |
| `*/typescript` | `npm install` | `npm test` (Vitest) | `npm run check` (selmer, big-config) / `npm run typecheck` (once); `npm run build` | `npm run once -- <args>` (during dev) |
| `launcher/python` | `uv sync` | (no tests) | — | `uv run bc-pkg <owner/repo@ref> ...` |
| `launcher/typescript` | `npm install` | (no tests) | — | `node bin/bc-pkg.js <owner/repo@ref> ...` |

Run a single test:
- Clojure: `clojure -M:test -v <ns>/<test-name>` (cognitect test-runner)
- Python: `uv run pytest tests/test_foo.py::test_name`
- TypeScript: `npx vitest run test/foo.test.ts -t "name"`

## The `once` build artifact contract

`plan.md` documents an active goal: parity of the `bb once build` output across all three `once` implementations. The expected artifact path is `<leaf>/.dist/profile-alpha-d2264632/`. The Clojure version (`bb once build` in `once/clojure`) is the reference; the Python and TypeScript versions should produce byte-equivalent output.

When working on `once`, treat `.dist/` as generated output — never edit it as source.

## Architecture concepts (shared across all three `once` implementations)

These are the load-bearing ideas; the per-language `CLAUDE.md` files have the details.

- **Six-stage create pipeline** (`once package create`): `tofu` → `tofu-smtp` → `tofu-dns` → `tofu-smtp-post` → `ansible-local` → `ansible`. `delete` reverses the four Tofu stages.
- **Profiles** live in `options.{clj,py,ts}` and compose private sub-profile maps (cloud provider × `resend` × `cloudflare` × `r2` × `deploy`) into named application profiles. An active profile is selected by a single top-level binding (`(def bb ...)` in Clojure; `export const bb = ...` in TypeScript; analogous in Python).
- **Parameter flow**: profile params → `BC_PAR_*` env-var overrides (uppercased, hyphens/dots → underscores) → params extracted from Tofu outputs of earlier stages.
- **Templates** under `src/resources/.../tools/` use `<{ var }>` for file content and `{{ var }}` for directory selection (provider switching). Rendered into `.dist/` by `big-config`'s renderer.
- **Plugin system**: the remote-state backend (S3 / R2 / local) is injected after each render step via `big-config`'s pluggable step registry.

## Workflow engine concepts (shared across all three `big-config` implementations)

- An `opts` map (`Record<string, any>` / `dict` / Clojure map) is threaded through step functions. Reserved keys are namespaced strings: `big-config/exit` (0 = success), `big-config/err`, `big-config/stack-trace`, `big-config.workflow/steps`, `big-config.workflow/params`, etc.
- Step functions take `opts` and return `opts`. Composition: `core.workflow` / `createWorkflow` / equivalent assembles a sequence of steps; `workflow_star` / `createWorkflowStar` / `create-workflow-star` does subworkflow isolation; `run_steps` / `runSteps` / `run-steps` runs a named-step sequence.
- Shell-command execution goes through a `runner` seam (`big-config.run/runner`, `run.runner`, etc.) so tests can swap in a fake runner instead of spawning processes.
- Do not add error handling for cases that cannot happen — step failures are reported through `big-config/exit` and `big-config/err`, not exceptions.

## Launcher (`bc-pkg`) concepts

`launcher/python` (PyPI: `bc-pkg`) and `launcher/typescript` (npm: `bc-pkg`) are two implementations of the same CLI bootstrap behaviour:

- Accepts `<owner/repo@ref>` on first run; resolves `ref` to a 40-char commit SHA and pins it locally.
- Infers the target language (Clojure / Python / TypeScript) from the pinned GitHub content, copies the package's root `run` file into the cwd, and writes a language-native manifest (`deps.edn` + `bb.edn` / `pyproject.toml` / `package.json`).
- Forwards the rest of the command to that pinned target package.
- Refuses to update implicitly if the directory is already initialised for a different repo/ref/SHA.

Both launchers must produce equivalent on-disk artifacts for the same `<owner/repo@ref>` — keep behaviour parity. They have **no runtime dependencies** outside of the stdlib (Python) / Node built-ins (TypeScript). The Python launcher targets Python ≥ 3.11; the TypeScript launcher targets Node ≥ 18.

## Cross-cutting conventions

- **Naming of keys at boundaries**: kebab-case strings (matching template variable names) for params; namespaced strings for engine reserved keys. Python and TypeScript implementations preserve the kebab-case string keys rather than converting to snake_case / camelCase.
- **Entry-point suffix `*`**: Clojure uses `tofu*`, `once*`, `onceStar`, etc. for CLI/REPL entry-points wrapping the underlying workflow step. TypeScript mirrors with `onceStar`, `tofuStar`. Python uses `_star` / explicit CLI wrappers (see `once/python/src/once/cli.py`).
- **Pure report builders are separate**: `validate-report` / `describe-report` (Clojure), `validateReport` / `describeReport` (TS), and the Python equivalents are pure and accept injected dependencies — keep that separation so tests can stay process-free.
- **Credentials**: never in source. Live in `.envrc.private` (gitignored) per leaf.
- **`prevent_destroy = true`** is the default on compute resources. Override with `BC_PAR_COMPUTE_PREVENT_DESTROY=false` before `once package delete`.

## Caddyfile

The root `Caddyfile` serves `manual.bigconfig.website` from this directory (specifically `index.html` and `changes.html`). It's the publish target for the unified manual referenced in `03.md`. Editing the manual means editing the HTML in this directory, not inside a leaf.

## Git

The leaves are independent repos. **Stay on the working branch (`main` or `clojure`, depending on the leaf — see the leaf's `CLAUDE.md`) and do not commit unless explicitly asked.** Do not create feature branches across leaves implicitly; multi-leaf changes are coordinated by the user.
