# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository shape

This is a multi-language polyrepo holding four nested libraries/packages (each implemented three times in Clojure, Python, TypeScript) plus a two-language `bc-pkg` launcher:

```
bigconfig/
├── selmer/{clojure,python,typescript}      # Django-style template engine
├── big-config/{clojure,python,typescript}  # BigConfig SDK workflow + render engine (uses selmer)
├── once/{clojure,python,typescript}        # Infra automation CLI (uses BigConfig SDK)
├── walter/{clojure,python,typescript}      # Dev-workstation provisioner (uses once + BigConfig SDK)
└── launcher/{python,typescript}            # `bc-pkg` bootstrap launcher (PyPI / npm)
```

Each of the fourteen leaves is an independent project with its own build system, tests, and `CLAUDE.md` / `README.md`. **Always read the leaf's `CLAUDE.md` before editing inside it** — the per-language conventions, what-to-avoid lists, and entry-point naming differ.

The root directory itself is not a git repo and has no build system; it's a workspace that holds the projects side-by-side so they can reference each other by relative path during development.

## Dependency direction

```
once / walter  ──depends-on──▶  BigConfig SDK (`big-config`)  ──depends-on──▶  selmer
walter         ──also-depends-on──▶  once
```

Within a single language, projects consume each other either as published packages or as local-path overrides:

- **Clojure**: `once/clojure/deps.edn` pins the Clojure SDK package (`big-config`) by `:git/sha` (under the coordinate `io.github.amiorin/big-config`) and has a commented `:local/root "../../big-config/clojure"` line — swap to develop against local SDK source. `walter/clojure/deps.edn` pins the Clojure SDK package (with an explicit `:git/url` to `bigconfig-ai/big-config`) and `io.github.bigconfig-ai/once`. The Clojure SDK (`big-config/clojure`) uses Selmer from Maven (`selmer/selmer 1.13.1`).
- **Python**: `once/python/pyproject.toml` pins the Python SDK package (`big-config`) to a Git commit; `walter/python/pyproject.toml` pins the Python SDK package and `once` to Git commits; the Python SDK (`big-config/python`) pins `selmer` to a Git commit. Use `uv sync` to resolve.
- **TypeScript**: `once/typescript/package.json` pins the TypeScript SDK package (`big-config`) to a GitHub commit; `walter/typescript/package.json` pins the TypeScript SDK package and `once` to GitHub commits; the TypeScript SDK (`big-config/typescript`) pins `selmer` to a GitHub commit. To develop against local SDK source, override a dependency with a `file:` path (e.g. `"big-config": "file:../../big-config/typescript"`) and re-run `npm install`.

Cross-language work that touches the engine surface (e.g., adding a step type, a renderer feature, or a workflow primitive) needs the change applied in all three SDK implementations, then re-verified in the consumers downstream.

The `launcher/` projects (`bc-pkg`) are independent of the `selmer → BigConfig SDK (big-config) → once` chain: they are bootstrap CLIs that resolve a GitHub-pinned BigConfig package and forward commands to it. They do not import any of the three SDK libraries.

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
- **Templates** under `src/resources/.../tools/` use `<{ var }>` for file content and `{{ var }}` for directory selection (provider switching). Rendered into `.dist/` by the BigConfig SDK renderer.
- **Plugin system**: the remote-state backend (S3 / R2 / local) is injected after each render step via the SDK's pluggable step registry.

## Workflow engine concepts (shared across all three BigConfig SDK implementations)

- An `opts` map (`Record<string, any>` / `dict` / Clojure map) is threaded through step functions. Reserved keys are namespaced strings: `big-config/exit` (0 = success), `big-config/err`, `big-config/stack-trace`, `big-config.workflow/steps`, `big-config.workflow/params`, etc.
- Step functions take `opts` and return `opts`. Composition: `core.workflow` / `createWorkflow` / equivalent assembles a sequence of steps; `workflow_star` / `createWorkflowStar` / `create-workflow-star` does subworkflow isolation; `run_steps` / `runSteps` / `run-steps` runs a named-step sequence.
- Shell-command execution goes through a `runner` seam (`big-config.run/runner`, `run.runner`, etc.) so tests can swap in a fake runner instead of spawning processes.
- Do not add error handling for cases that cannot happen — SDK step failures are reported through `big-config/exit` and `big-config/err`, not exceptions.

## Launcher (`bc-pkg`) concepts

`launcher/python` (PyPI: `bc-pkg`) and `launcher/typescript` (npm: `bc-pkg`) are two implementations of the same CLI bootstrap behaviour:

- Accepts `<owner/repo@ref>` on first run; resolves `ref` to a 40-char commit SHA and pins it locally.
- Infers the target language (Clojure / Python / TypeScript) from the pinned GitHub content, copies the package's root `run` file into the cwd, and writes a language-native manifest (`deps.edn` + `bb.edn` / `pyproject.toml` / `package.json`).
- Forwards the rest of the command to that pinned target package.
- Refuses to update implicitly if the directory is already initialised for a different repo/ref/SHA.
- Also accepts a **local path** (`./`, `../`, `/`, `~`, or `.`/`..`) instead of `<owner/repo@ref>` for live local development: it writes native local-path deps (`:local/root` / `file:` / editable `[tool.uv.sources]`), symlinks the `run` file, and does no SHA pinning. Switching an initialised directory between local and GitHub (or to a different repo/ref/SHA or local path) is a hard error.

Both launchers must produce equivalent on-disk artifacts for the same `<owner/repo@ref>` — keep behaviour parity. They have **no runtime dependencies** outside of the stdlib (Python) / Node built-ins (TypeScript). The Python launcher targets Python ≥ 3.11; the TypeScript launcher targets Node ≥ 18.

## Cross-cutting conventions

- **Naming of keys at boundaries**: kebab-case strings (matching template variable names) for params; namespaced strings for engine reserved keys. Python and TypeScript implementations preserve the kebab-case string keys rather than converting to snake_case / camelCase.
- **Entry-point suffix `*`**: Clojure uses `tofu*`, `once*`, `onceStar`, etc. for CLI/REPL entry-points wrapping the underlying workflow step. TypeScript mirrors with `onceStar`, `tofuStar`. Python uses `_star` / explicit CLI wrappers (see `once/python/src/once/cli.py`).
- **Pure report builders are separate**: `validate-report` / `describe-report` (Clojure), `validateReport` / `describeReport` (TS), and the Python equivalents are pure and accept injected dependencies — keep that separation so tests can stay process-free.
- **Credentials**: never in source. Live in `.envrc.private` (gitignored) per leaf.
- **`prevent_destroy = true`** is the default on compute resources. Override with `BC_PAR_COMPUTE_PREVENT_DESTROY=false` before `once package delete`.

## Walter package concepts

`walter/{clojure,python,typescript}` is a second BigConfig package (`bigconfig-ai/walter`) that provisions a cloud VM (or targets an existing `no-infra` host) and configures it as a development workstation. It reuses Once's shared `tofu` and `ansible-local` stages (depending on the `once` package) and owns its Walter-specific `ansible` stage, roles, and data. Its package workflow is `tofu → ansible → ansible-local`; `delete` destroys the compute Tofu stage. `package build` output is verified byte-for-byte against the Clojure reference artifact under `walter/clojure/.dist/walter-<hash>/`.

## Workspace tooling (root `run`)

The root `run` is a Babashka script (namespace `run`) exposing grouped command helpers for the workspace itself (not a BigConfig package):

- `bb run` — top-level help.
- `bb run git setup [--dry-run] [--root-dir DIR]` — clone/update the expected workspace with SSH remotes, eight primary clones, and nine linked worktrees for sibling language branches; existing repos are validated and pulled with `--ff-only origin <branch>`.
- `bb run git report [--porcelain] [--root-dir DIR]` — report dirty/clean/no-tracked-files status for every nested git repo.
- `bb run git commit [--dry-run] [--root-dir DIR]` — run `pi --print --model deepseek-v4-flash "commit and push"` in each dirty repo.

## Caddyfile

The root `Caddyfile` serves `manual.bigconfig.website` from this directory (specifically `index.html` and `changes.html`). It's the publish target for the unified manual referenced in `03.md`. Editing the manual means editing the HTML in this directory, not inside a leaf.

## Git

The leaves are independent repos. **Stay on the working branch (`main` or `clojure`, depending on the leaf — see the leaf's `CLAUDE.md`) and do not commit unless explicitly asked.** Do not create feature branches across leaves implicitly; multi-leaf changes are coordinated by the user.
