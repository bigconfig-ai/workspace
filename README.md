# BigConfig Workspace

This workspace contains the BigConfig family of SDKs and packages, implemented across Clojure, Python, and TypeScript.

## Projects

| Directory | Purpose | Languages |
| --- | --- | --- |
| `selmer/` | Django-style template engine and ports. | Clojure, Python, TypeScript |
| `big-config/` | BigConfig SDK: workflow, render, command-runner, locking, and OpenTofu helper engine. | Clojure, Python, TypeScript |
| `once/` | Infrastructure automation package for deploying ONCE with OpenTofu and Ansible. | Clojure, Python, TypeScript |
| `walter/` | Infrastructure automation package for provisioning developer workstations. | Clojure, Python, TypeScript |
| `launcher/` | `bc-pkg` bootstrap launcher for GitHub-pinned BigConfig packages. | Python, TypeScript |

Dependency direction:

```text
once / walter  ->  BigConfig SDK (`big-config`)  ->  selmer
launcher       ->  target package selected at runtime
```

## Repository layout

```text
bigconfig/
├── selmer/{clojure,python,typescript}
├── big-config/{clojure,python,typescript}
├── once/{clojure,python,typescript}
├── walter/{clojure,python,typescript}
├── launcher/{python,typescript}
└── plans/
```

Each leaf directory is an independent package with its own build system, tests, README, and development notes.

## Development commands

Run commands from the relevant leaf directory.

| Leaf type | Install / sync | Test | Typecheck / build | Run CLI |
| --- | --- | --- | --- | --- |
| `*/clojure` | dependencies resolve via `clojure` / `bb` | `clojure -M:test` | — | `bb run ...` where supported |
| `*/python` | `uv sync` | `uv run pytest -q` | — | `uv run <entry-point> -- ...` |
| `*/typescript` | `npm install` | `npm test` | `npm run check`, `npm run typecheck`, or `npm run build` depending on the leaf | `npm run <script> -- ...` |

Common examples:

```sh
cd selmer/typescript && npm test
cd big-config/python && uv run pytest -q
cd once/clojure && bb run once package build
cd walter/typescript && npm run walter -- package build
cd launcher/python && uv run bc-pkg bigconfig-ai/once@clojure package validate
```

## Workspace tooling

The root `run` is a Babashka script (run it as `bb run ...`) that operates on the workspace itself rather than on any single leaf. It groups its commands under `git`:

```sh
bb run                      # top-level help
bb run git setup --dry-run  # preview workspace clone/worktree/fetch/pull actions
bb run git setup            # create/update the expected clone + worktree layout
bb run git report           # dirty/clean status for every nested git repo
bb run git report --porcelain
bb run git commit --dry-run # preview committing & pushing each dirty repo
```

`bb run git setup` uses SSH remotes and recreates the workspace as seven primary clones plus nine linked worktrees for the language branches; existing repos are validated and updated with `git pull --ff-only origin <branch>`. `bb run git commit` runs `pi --print --model deepseek-v4-flash "commit and push"` in each dirty repo; `--root-dir DIR` targets somewhere other than the current directory.

## BigConfig package model

BigConfig packages render templates and orchestrate tools through named workflow steps. The main runtime concepts are:

- an `opts` map/dict/object threaded through every step;
- reserved namespaced keys such as `big-config/exit`, `big-config/err`, and `big-config.workflow/steps`;
- Selmer-based rendering from `src/resources/.../tools/` into `.dist/`;
- pluggable workflow steps for package-specific behavior;
- a command-runner seam so tests can avoid spawning real processes.

Template conventions used by the packages:

- `<{ var }>` renders BigConfig SDK/Selmer variables in file content;
- `{{ var }}` is used for directory/provider selection and for templates that must preserve Ansible-style braces.

Generated `.dist/` directories are build artifacts and should not be edited directly.

## Package highlights

### Selmer

Selmer is the template engine layer. The Clojure implementation tracks the upstream Selmer project; Python and TypeScript are ports used by the language-native BigConfig SDK implementations.

### BigConfig SDK

The SDK provides the workflow engine, renderer, shell runner, Git lock helpers, plugin registry, custom filters, and OpenTofu/Terraform construct helpers consumed by packages such as Once and Walter.

### Once

Once automates a six-stage create pipeline:

```text
tofu -> tofu-smtp -> tofu-dns -> tofu-smtp-post -> ansible-local -> ansible
```

It supports cloud compute providers, DNS/SMTP setup, remote state backends, validation, description reports, and `BC_PAR_*` environment overrides.

### Walter

Walter provisions or targets a host and configures it as a development environment. It reuses shared Once infrastructure stages where possible and owns its Walter-specific Ansible roles/data.

### Launcher (`bc-pkg`)

`bc-pkg` initializes a local BigConfig CLI from a GitHub spec such as:

```sh
uvx bc-pkg bigconfig-ai/once@clojure package validate
npx bc-pkg bigconfig-ai/walter@typescript package build
```

On first run it resolves the ref to a commit SHA, writes a language-native manifest, copies the package `run` file, and forwards subsequent commands to the pinned target.

It also accepts a **local path** instead of a GitHub spec for live local development — it wires native local-path dependencies, symlinks the `run` file, and does no SHA pinning:

```sh
uvx bc-pkg ../once/python package build
npx bc-pkg ../once/typescript package build
```

## Configuration and credentials

- Use `BC_PAR_*` variables to override package parameters.
- Keep private credentials out of source; use each leaf's `.envrc.private` convention where present.
- Destructive infrastructure operations should be run only with deliberate parameter overrides, for example `BC_PAR_COMPUTE_PREVENT_DESTROY=false` for Once delete flows.

## Documentation

Start with the README in the leaf you are using:

- `selmer/*/README.md`
- `big-config/*/README.md`
- `once/*/README.md`
- `walter/*/README.md`
- `launcher/*/README.md`

The `plans/` directory records active and completed implementation plans for cross-language parity work.
