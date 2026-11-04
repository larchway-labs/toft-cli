---
name: toft-sdk
description: Write an app that runs on Toft — what the platform sets in its environment, how it is detected and built, what `toft.toml` declares (env, storage, jobs, schedules, runtime pins), and the Toft app SDK for Python, Node, Go and R (`toft.app.can`, scratch and storage, the app's JSON document, Slack and email, background jobs and their status page, who the viewer is and their role). Load it when writing or fixing code that will be deployed to Toft, when an app works locally and misbehaves once deployed, or when an app needs to send a notification, store a file, or start background work.
---

# Writing an app for Toft

An app is ordinary code: Toft detects what it is, installs its dependencies,
starts it and puts it behind a URL. Nothing needs importing to be deployable —
the SDK is for what only the platform can do. Driving `toft` itself (deploy,
env, logs, jobs) is the **toft-cli** skill.

## The contract every app keeps

| | |
|---|---|
| `PORT` | listen on it, never a port you chose. A service's only — a job run gets no `PORT` or `HOST` |
| `HOST` | bind it. `app.listen(port)` alone binds `0.0.0.0`, reachable around the platform |
| `BASE_PATH` | where you are mounted, e.g. `/apps/reports`. Always set, in jobs too |

- **The gateway strips `BASE_PATH` before the request reaches you**: route on
  `/summary`, not `/apps/reports/summary`. Next.js, Streamlit and marimo are the
  exception — the platform tells them their mount point and forwards the full
  path, which they expect.
- **Links, form actions and asset URLs carry `BASE_PATH`.** A root-absolute
  `/styles.css` asks the *platform*, not you, and 404s.
- **Frameworks that read the mount point report the full path.** FastAPI and
  Starlette are told it as `root_path`, so `request.url.path` includes
  `/apps/<slug>` — build links from it as they are, without adding `BASE_PATH`
  again; routes still match the stripped path.
- **Redirects need not.** The proxy prefixes a root-relative `Location: /done`
  on the way out (Next.js included) and leaves one that already carries it alone.
- **Anything else is an environment variable** someone sets on the app's
  Settings page or with `toft env set`; a restart applies it. Declare what the
  code needs under `[env]` in `toft.toml`. **A `.env` file is never deployed** —
  `load_dotenv()` leaves already-set variables alone, so local code keeps working.
  The process never receives the platform's own secrets.

**What the platform sets** (the first three rows are reserved — an app variable of that name is `reserved_env_name`):

| Who gets it | Variables |
|---|---|
| every workload | `BASE_PATH`; `TOFT_SCRATCH_DIR` and `TMPDIR` (scratch); `TOFT_API_URL`, `TOFT_APP_SLUG`; `VIRTUAL_ENV` / `R_LIBS_SITE` |
| a workload with storage mapped | `TOFT_STORAGE` (JSON list of mounts) — **absent, not `[]`, when nothing is mapped**; read it through `mounts()` |
| the service only | `PORT`, `HOST`, `TOFT_APP_TOKEN`, `TOFT_APP_ID`, `TOFT_ROLE_KEY` |
| a job run only | `TOFT_RUN_ID`, `TOFT_JOB_NAME`, `TOFT_TRIGGER`, `TOFT_TRIGGER_ROLE`, `TOFT_PARAMS`, `TOFT_PARAM_<NAME>`, `TOFT_SCHEDULED_FOR`, `TOFT_RERUN_OF`, `TOFT_DEADLINE`, `TOFT_JOB_TOKEN`, `TOFT_OUTPUT_URI` |
| defaults your own value overrides | `NODE_ENV=production` (Node/Next.js); `GOMAXPROCS`, `OMP_NUM_THREADS`, `MC_CORES` = CPU limit rounded up to whole cores, `UV_THREADPOOL_SIZE` = that or 4 |

A CPU limit is CPU time, not cores: an app gets one core by default, a job two;
more threads are slowed, not stopped. Held at its limit for over 15 minutes, an
app raises `app_cpu_throttled` to its owners.

## How the build decides what your app is

First match wins:

| Order | Framework | Detected by |
|---|---|---|
| 1 | batch | a `[batch]` table (below) — never inferred |
| 2 | static (declared) | a `[static]` table — overrides everything after it |
| 3 | Next.js | `next.config.{js,ts,mjs}`, or `next` in `package.json` deps. Needs a `build` script; do **not** set `basePath` or `output` |
| 4 | Node | `package.json` with a `start` script (`build` runs first if present) |
| 5 | Go | `go.mod` plus `package main` at the module root, else the first `cmd/*` |
| 6 | Shiny (document-shaped) | an `.Rmd` declaring `runtime: shiny` |
| 7 | R Markdown / Quarto (R) | one root `.Rmd`, or one `.qmd` whose engine is R (`engine: knitr`, a `knitr:` key, or R chunks) |
| 8 | marimo | one root `.py` that imports marimo and builds a `marimo.App` — run per viewer, not rendered |
| 9 | notebook | one root `.ipynb`, or a `.qmd` that is not R — rendered at build time |
| 10 | Shiny | `app.R`; `ui.R` **and** `server.R`; or `server.R` + `www/index.html` (`.r` works too) |
| 11 | plumber | `plumber.R`, or a root `.R` file with a route annotation — `#* @get /x` (any of `@get`, `@post`, `@put`, `@delete`, `@head`, `@options`, `@patch`, `@use`; `#'` works too). A bare `#*` line is not one: such a tree is `unsupported_framework` |
| 12 | Flask / FastAPI / Streamlit / Python | `requirements.txt`, `pyproject.toml` or `Pipfile` (framework read from it) **plus** a root `app.py`, `main.py`, `streamlit_app.py`, `server.py` or `wsgi.py` — no entry file, no deploy |
| 13 | static | only with none of `package.json`, `requirements.txt`, `pyproject.toml`, `Pipfile`, `go.mod`, and an HTML entry |
| 14 | Python | none of the files above and no HTML, but a root `app.py`, `main.py`, `streamlit_app.py`, `server.py` or `wsgi.py` — a plain Python app with no dependencies, run with `python <entry>` |

Documents (rows 7, 9) are rendered **once, at build time** and served as files:
no process behind the page, whatever a chunk prints is published, and a re-render
is a deploy (or a `[render]` schedule). The render is a build step, not a
workload, so an SDK call from a chunk or cell answers `off_platform` — put
platform work in a job. Several root candidates are refused,
named; pick one with `[notebook] file = "reports/weekly.qmd"` or
`"reports/weekly.Rmd"` (also reaches a subdirectory). `[notebook] engine` is
`nbconvert`, `quarto`, `knitr` or `jupyter`; an `.Rmd` takes `knitr` or
nothing. An `.Rmd` knits in its own folder, as RStudio's Knit button does, so
its relative paths start there.

Build traps:

- **Never set `NODE_ENV=production` as an app variable.** It reaches the build,
  npm reads it as `--omit=dev`, and the build fails (`vite: command not found`).
  `toft env set` warns when you do; the platform already sets it for the process.
- **Install scripts do not run** (`--ignore-scripts`): `prisma generate`, a
  native rebuild, anything in `postinstall` belongs in your `build` script.
- **npm only.** A committed `package-lock.json` means `npm ci` and must be in
  sync; a yarn/pnpm lockfile is passed over (the build log says so).
- **A Go app cannot run an npm build.** Commit built assets. The binary is
  `./toft-app` (`go build -o toft-app`).
- **A frontend-only repo with `package.json`** is not static: add a server and a
  `start` script, or commit the build output and declare `[static] root = "dist"`.
- **Pin language versions in `toft.toml`**, never by approximation — see
  `[runtime]`. `engines.node` and `.nvmrc` are **not read**.

R:

- **Commit `renv.lock`** (`renv::init()`, `renv::snapshot()`). Without it the
  build installs nothing and says so (`toft check` warns `no_renv_lock`): a
  Shiny or plumber app dies at its first `library()` (`not_ready`), a batch
  app's jobs each fail at theirs, and an R
  Markdown or Quarto document fails the deploy at the render step, naming the
  missing package. The exceptions are the SDK's own dependencies — `jsonlite`,
  `curl` and `openssl`, and what they pull in (`askpass`, `sys`) — which every R
  release has; `library(glue)` with no lockfile still fails.
- Packages come from a binary repository; one without a binary for the
  platform (often an old pinned version) compiles from source — slow, on every
  cold build. Keep the lockfile small.
- **Keep helper scripts out of the root**: a root `.R` with a `#* @get`-style
  annotation makes the repository plumber.
- **Do not bind a port or build a URL.** The platform runs `runApp` / `pr_run`
  with its own host and port. Shiny inherits the mount path; annotate plumber
  routes from the root (`#* @get /summary`).
- **Shiny and plumber are one single-threaded R process**: a four-second
  reactive is a four-second queue for every viewer. Slow work goes to a job.

**Document apps can run jobs**: a job runs a command from the same release (its
venv or R library included), with what any job has — `toft.run`, `toft.mounts()`,
notify and storage — but nothing serves a request, so no viewer and no in-page
Run button; a `schedule`, `toft job run` or Toft's Run button starts it —
and viewer identity is refused on one, 409 `document_app`. A
**static** app has no runtime: `[jobs]` there is `manifest_invalid`, and
attaching storage or an integration, or turning viewer identity on, is 409
`static_app`.

## `toft.toml`

Optional, committed, read at every deploy. Unknown tables are ignored, but **the
build log and `toft check` name every key nothing read** (`manifest_unread`) —
a misspelled key is a setting that stayed at its default, on a green deploy.
`[app]` reads `slug`, `install`, `installs."<url>".slug` and `name` and nothing else —
`name` is the display name `toft create` gives a new app when `--name` is not
passed (the flag wins); it is read at create only, and a later rename in the app's
settings is never undone by a deploy.
`toft check` validates the file and prints the plan before you deploy; every
problem it finds carries a `code` and a `hint` naming the line to write instead.

```toml
[app]
slug = "reports"                  # written by `toft link`
name = "Reports"                  # the display name at `toft create`; --name wins

[runtime]
python = "3.13"                   # or a range: ">=3.12,<3.14"; node = "22"; r = "4.5"

[static]
root = "dist"                     # document root; "." is the repository itself
entry = "report.html"             # what the app's URL serves
fallback = true                   # client-side routing

[env]
DB_HOST     = "db.internal"       # visible, with a default
API_URL     = {}                  # visible, no default
LOG_LEVEL   = { default = "info" }
DB_PASSWORD = { sensitive = true } # a secret: never a default

[[storage]]                       # storage an administrator already created
name   = "sales-data"
access = "full"                   # read | write | full; left out: read, or what its storage root serves
folder = "2026"                   # optional: one folder of the resource
path   = "/data/sales"            # optional: default /storage/<name>[/<folder>]

[restart]                         # serving apps only
schedule = "0 4 * * *"
timezone = "Europe/London"        # optional; UTC without it

[render]                          # document apps only: re-render on a timetable
schedule = "0 6 * * 1"

[jobs.nightly-report]
command  = "python -m reports.nightly"   # or args = ["job", "nightly"]: the Go binary's arguments (a leading "./toft-app" is dropped)
timeout  = "45m"                  # duration ("90s", "45m", "2h", "7d") or seconds; 1 s to 7 days; omitted = install default
schedule = "0 3 * * *"            # optional; omit for a job something starts
timezone = "Europe/London"        # optional; never a CRON_TZ= prefix
overlap  = "skip"                 # queue (default) | skip — scheduled firings only
expect_within = "26h"             # optional: owners told if no success in this long
notify   = "failures"             # none (default) | failures | always

[jobs.nightly-report.params.region]
type     = "string"               # string | int | float | bool
default  = "emea"                 # or required = true — never both
help     = "Which region to report on"
choices  = ["emea", "amer", "apac"]
```

**`[runtime]`** — a pin is a quoted string (`node = 22` is refused: *write node
= "..."*). Node is matched on the major alone, Python and R on major.minor;
ranges use `>=`, `<`, `==3.13.*`. A pin of the wrong width is refused with your
own line at the right one: `"22.1.0"` → write `"22"`, `"3.13.18"` → `"3.13"`,
`"3"` → `"==3.*"`. A pyproject `requires-python` moves the Python default only
when it excludes it; a pin it excludes is warned about
(`pin_excluded_by_requires_python`). A version the install lacks is
`runtime_version`, with a hint; `toft whoami` lists what it carries. A
dependency with no wheel for the default Python (pyyaml on 3.15, so marimo) is
fixed by pinning an earlier line here — the dependency scan honors the pin.

**Go is the exception**: `go.mod`'s `go` line is a floor, not a pin, and
`[runtime] go` is refused. A `go` line newer than the install carries is a
warning (`go_toolchain_fetched`), not a refusal — the build has the go command
fetch that toolchain, and fails only if it cannot.

**`[env]`** — each deploy adds a declared variable the app lacks, with its
default and flag; it never changes or removes an existing one, and skips a name
a credential supplies. An unfilled variable arrives in the app as `""`, a secret
included — `toft env` and the console show an unfilled secret as *not set* until
it is filled in. Refusals: a secret with a default `sensitive_default`
(hint: `toft env set --from-file`); any other shape `env_entry_invalid`; a bad
name `invalid_env_name`; a platform name `reserved_env_name`.

**`[[storage]]`** — attaches existing storage; the code reads it **by name**
(`toft.storage("sales-data")`, `toft.store(…)`), never by path. The app's owner
must be able to attach each entry, and the deployer too when the deploy adds one
or raises its level. Mounts change at the end of the deploy, so don't mint a
signed URL for a newly declared store at boot. Removing an entry detaches it at
the next deploy and keeps its files. Refusals (at upload, `toft check` and
deploy): `storage_entry_invalid`, `storage_name_ambiguous` (same name+folder
twice), `storage_path_taken`, `storage_unknown`, `storage_not_attachable_by_owner`,
`storage_not_attachable_by_you`, `storage_level_above_ceiling`,
`storage_conflicts_console_mapping`, `storage_deleting`, `storage_needs_root`.
`storage_not_attachable_by_you` is also what a `toft store` grant gets: a grant
lets a person put and get objects, it is not a right to attach — that needs a
manage delegation from an administrator, to you or the app's owner. A name you
hold nothing on reads `storage_unknown`, whether or not it exists — if an
administrator created it, ask them to delegate it to you or the app's owner.

**`[jobs.<name>]`** — the only way a job exists (no UI or CLI creates one); it
versions and rolls back with the code. Names: lowercase letters, digits, inner
dashes. Parameters are enforced at start, all 400 and not retryable:
`param_required`, `param_type`, `param_choice`, `param_unknown`; a `default`
fills an absent one. A job declaring no params takes any keys — but `params` is still a JSON object (`"x"`, `[1]` or `5` is `param_type`, declared params or not). CLI `--param` strings
are coerced to the declared type; a `float` param arrives as a float (`2` and
`"2"` are `2.0`), defaults included.

- **Refused as `removed_key`** (hint names the replacement): `retries` (runs are
  never retried; a person reruns), `viewer_runnable` (the app's own button
  decides), `enabled` (pause in Toft), **`memory` and `cpu`** (an administrator
  sets a job's limits on the Automation tab; default 1 GB / 2 cores as shipped),
  and a `[tasks]` table. `enabled` in `[restart]`/`[render]` likewise.
- A `timeout` above the install ceiling is `limit_exceeds_ceiling`, the largest
  allowed value in the hint.
- `overlap = "queue"` holds a firing behind the previous scheduled run; `"skip"`
  records a `skipped` run. A firing refused by a full queue is also `skipped`.
  Runs somebody starts are never held behind scheduled ones.
- `notify` alerts owners per failed (`failures`) or finished (`always`) run;
  skipped and cancelled say nothing.
- A job's `command` runs through `/bin/sh -c`, so the shell's quoting and
  expansion apply: in `Rscript -e "cat(toft::current_run()$trigger)"` the
  `$trigger` is expanded (to nothing) before R sees it — use single quotes
  inside. `args` is never passed through a shell, but only a Go release takes
  it: on any other app `args` is `manifest_invalid` / `invalid_job_command`.
- A Go job runs the built binary and dispatches on its arguments:
  `command = "./toft-app job nightly-report"`, or `args = ["job",
  "nightly-report"]` — on a `[batch]` Go app too. `args` are the binary's
  arguments; a leading `./toft-app` there is dropped, never passed as
  `os.Args[1]`.
- Jobs run with or without a cluster (a container per run, or a process on the
  install's machine) with the same limits and record.

**`[restart]` / `[render]`** — one each per app, at most once an hour
(`schedule_too_frequent`). `[restart]` on a batch app is `restart_no_service`,
on static or a document `restart_changes_nothing`; `[render]` on anything but a
document (marimo included) is `render_not_a_document`.

**`[batch]`** — a program with no web server: `[batch]` (plus
`language = "python" | "node" | "go" | "r"` if ambiguous). Dependencies install,
nothing starts, the work is its `[jobs]`; Restart/Stop answer `no_service`,
and turning viewer identity on is 409 `batch_app` — no page, so no viewer.
`[batch]` with `[static]` is refused.

## The SDK

Installed by the build from the platform binary — nothing to add to
`requirements.txt` or `package.json` (a copy you declare yourself is kept).

```python
import toft                                    # Python
```
```js
import toft from "@larchway/toft";             // Node, ESM; from CommonJS: await import(...)
```
```go
import "toft"                                  // Go; the build's go.work resolves it
```
```r
library(toft)                                  # R, in the release's renv library
```

Off-platform, calls that need the platform raise `off_platform` naming the
missing variable — **there is no dry-run mode**. `scratch_dir` works anywhere.
To compile or lint before the first deploy (in Go, `go build` fails on the
import without it), run `toft sdk vendor` — it writes `.toft/sdk-<lang>/` (and a
`go.work` for Go; ignore both in `.gitignore` or neither — `toft check` warns
`go_work_dir_excluded` when only the folder is). For R it is a package source
tree: `R CMD INSTALL .toft/sdk-r`, then `library(toft)`. Details: toft-cli skill.

### Spelling across languages

Python is the reference below; the others differ like this:

- **Node** — camelCase, options objects (`{ folder }`, `{ params }`), every
  network call async. `toft.app.id` / `.slug` are plain properties;
  `name()`, `mode()`, `basePath()`, `policy()`, `capabilities()`, `can()` are
  async — **a missing `await` renders `[object Promise]`** on a page that looks
  deployed. Run the entrypoint off-platform once to catch it.
- **Go** — `ctx` first on every network call; errors not exceptions; options
  are structs (`toft.EmailMessage{…}`, `toft.StartOptions{Params: …}`,
  `toft.WaitOptions{Timeout: …}`); exported `toft.App`, `toft.Data`,
  `toft.Notify`, `toft.Jobs`; JSON numbers in `Document.Data` are `float64`,
  in `Set`'s answer as in `Get`'s — `doc.Decode(&v)` (`(bool, error)`, false
  when nothing is stored) reads the document exact, an `int64` field getting
  the integer.
- **R** — functions, not methods (`store_upload(store("drop"), "x.csv")`, or
  the store's name: `store_upload("drop", "x.csv")`); a refusal is a condition
  of class `toft_error`. No `can()`, no session scratch, no Slack file upload,
  no `tail`. `viewer(headers)` is R's *who*; `viewer_jobs(req)` is the
  act-as-viewer object. Headers can be plumber's `req` / `req$HEADERS` or
  Shiny's `session$request`. `current_run()` names how a run started in
  `$trigger` (there is no `started_by`).

### When the platform says no

Branch on the fields, never the sentence:

| | Python / Node | Go | R |
|---|---|---|---|
| `code` — stable name | `err.code` | `err.Code()` | `e$code` |
| `retryable` — the platform's decision, not the status's | `err.retryable` | `err.Retryable()` | `e$retryable` |
| `hint` — next step, may be absent | `err.hint` | `err.Hint()` (`""`) | `e$hint` (NULL) |

Go: `toft.AsError(err)`, or `errors.As` to `*toft.QueueFullError` (`InFlight`,
`Limit`) / `*toft.VersionConflictError`. R: `tryCatch(…, toft_error = function(e) …)`.
R: a request that never got an answer is a `toft_error` too (`code` `""`,
`retryable` TRUE), not curl's own condition.
`retryable` falls back to 429/5xx only when the platform said nothing. Log the
`hint`. The SDK resends a request once on its own only when it cannot have
reached a handler — a 429 from the rate limiter, a connection that never opened
— or when sending it twice is harmless: a GET, or a write carrying an
`Idempotency-Key`, after a 5xx or a dropped connection. An unkeyed POST, PUT or
DELETE that got a 5xx is not resent (still `retryable`: yours to decide), and a
timeout is never resent. A retryable 4xx is yours to loop on, honoring `retry_after` / `retryAfter` /
`RetryAfter`.

**A refusal the SDK makes itself is always coded and never retryable** — a bad
argument, a missing local file, a call off the platform. Only a request that
failed in transport, never reaching the platform, is uncoded and retryable, so
an agent's retry loop cannot spin on a local mistake. An **object store** that
answers a signed URL with an error is coded too — `output_unwritable` (writing
a run's output), `output_unreadable` (reading it back), `store_refused` (any
`store` call) — with its `status`, and retryable only for a 429 or 5xx. A 2xx
answer whose body is not JSON (a web page from a proxy or sign-in page in
front of the install) is `not_toft`, with its `status`, in all four — and in Go
an empty body too (a 204 still answers: no viewer, a cancelled run).

Codes worth handling (all `retryable: false` unless noted):

| Area | Codes |
|---|---|
| raised by the SDK before any request | `bad_request` — an argument it will not send: blank text, an empty session id or job name, a `jobs.list` status that is not one of the eight run statuses (Node exports them as `RUN_STATUSES`, named and on the default `toft`), a `limit` out of range (Python and Node 1–200; Go and R non-negative — the API itself reads a `limit` outside 1–200, 0 included, as its default 50, silently), `progress` outside 0–100, `app.can("")`, `access_token("")`, a non-JSON body (NaN included), app data that is not an object (R: anything but a named list), a Python or Node `data.update()` given anything but a function, a scratch path outside the scratch root, an unreadable local file or a directory where a file was wanted, an object name that is not a string — `None`/`null` included — or a source path that is not a string, with the call that was made in the hint (`download(5)` is told `download("…")`), a `wait()` timeout that is negative, NaN or infinite or a `wait()` or `tail()` poll interval that is not positive (`tail` in Python and Node; all four, a finished run included; 0 is a valid timeout — Go's `PollInterval` left at its zero value means the 2 s default, and only a negative one is refused), a logs cursor that is negative or not a whole number (all four), a `data.update()` `attempts` that is not a whole number from 1 (all four: Go's `UpdateN`, R's `app_data_update(attempts =)`), a Go `Data.Update`/`UpdateN` given a nil function, an R `store_*()` call given no store or no object name (`store_list()`, `store_download(s)`), a Python `jobs.list(job="")` / `mine(job="")` (refused, not read as no filter). `not_found` — a local file that is not there (all four). `off_platform` — the platform's variables are absent, or a run handle made outside a job. Also `no_viewer`, `would_outlive_request`, `no_recipient`, `no_output` (a write with no output location), `storage_env_invalid` (a `TOFT_STORAGE` that is not JSON or not an array (`{}` included), an entry that is not an object, one without its `name`, `kind` or `access`, a `kind` other than `volume`/`store` or an `access` other than `read`/`write`/`full` — in all four, held to one shared vector; `path` is optional — a store reached by signed URL has none), `not_json` (`output_json()` / `outputJson()` / `OutputJSON` / `job_output(json = TRUE)` on bytes that are not JSON, an output written empty included, in all four — Go's `OutputJSON` answers `false` beside it, `true` only when `v` was filled; no output at all is `None`/`null`/`false`/`NULL`). A role word that is not one — `at_least("superuser")`, `caller_can(h, "")` — is `bad_request` (Go: `AtLeast` panics with that `*toft.Error`, having only a bool to return); `system`, `app` and `unknown` are roles and answer false. Every refusal an SDK raises itself carries a `hint`. Node: a negative or NaN `rateLimitTimeout`; any option a call does not take — `data.set(doc, { if_version })`, `storage(name, { fold })`, `jobs.list({ jobb })`, and an options object handed to a call that takes none, an empty `{}` included — `accessToken(kind, {…})`, `azureCredential(kind, {…})`, `data.get({…})`, `jobs.get(id, {…})`, `caller(h, {…})`, `mounts({…})`, `notify.status(id, {…})`, a run's `cancel`/`refresh`/`logs`/`output`, `progress(p, m, {…})`, `writeOutput(d, {…})`, `writeOutputJson(v, {…})`, `newSessionId({…})`, `app.name`/`mode`/`basePath`/`policy`/`capabilities`/`refresh({…})`, `app.can(c, {…})`, `viewer(h, {…})`, `respond(run, req, {…})`, `caller.atLeast(role, {…})`, `Run.fromEnv({…})`, a `Mount`'s `put`/`upload`/`download`/`remove` — is `bad_request` naming what it does take (a snake_case spelling gets the camelCase name in the hint); `run.logs(afterSeq)` takes a whole number from 0 and refuses anything else, an options object included; `notify.email(message, { idempotencyKey })` takes its key in either place, and two different ones are `bad_request`, and `jobs.list("name")` is `bad_request` — pass `list({ job: "name" })`; `RUN_STATUSES` and `TERMINAL_STATUSES` are read-only (`add` throws). Go adds `write_failed` (a local disk write), `scratch_unavailable`, `entropy_unavailable` |
| jobs | `queue_full` (429, **retryable**, `retry_after`; its hint is `toft job runs --app <slug>`, naming the app; the body's `in_flight` is the runs waiting in the queue, beside `limit`, the install's `max_queued_runs_per_app` — runs already running do not count against it), `wait_timeout` (**retryable**; the run is still going — in Go also a ctx whose deadline passed; a Go ctx cancelled outright is `wait_cancelled`, not retryable), `viewer_anonymous` (403), `act_for_required` (403: cancelling a run a person started that has not finished — only that person may; a finished one answers as a no-op), `job_send_only`, `param_*`, `idempotency_key_reused` (409: the same key with a different job, params or `scheduled_for`), `params_too_large` (413; the body's `limit_bytes`, 65536 — Python `e.body["limit_bytes"]`, Node `err.body.limit_bytes`, Go `e.Body["limit_bytes"]` (a `float64`), R `e$body$limit_bytes`) |
| storage | `not_mapped`, `ambiguous_mount`, `not_mounted`, `insufficient_access`, `already_exists`, `not_found`, `not_a_store`, `invalid_name`, `store_uploads_off` (404) |
| identity / data | `viewer_identity_disabled`, `version_conflict`, `rate_limited` (**retryable**), `too_large` (413: a document over 256 KiB; the body's `limit` is 262144) |
| integrations and tokens | `<kind>_off` (403: no connection, e.g. `sharepoint_off`, `slack_off`), `<kind>_not_attached` (403, e.g. `email_not_attached`, `slack_not_attached`), `<kind>_disabled`, `<kind>_tokens_off` (403), `unknown_capability` (400: a token kind the install does not offer), `token_too_wide` (409) |
| notify | `no_recipient`, `bad_recipient` (400: an address the platform will not send to), `too_many_recipients`, `too_large` (413: a message or attachment over the limit; the hint names the limit), `destination_not_allowed` (400: a `channel`, folder or other destination field, named with the integration it was sent to — the app's owners choose it on the Integrations tab), `sender_not_allowed` (400: `from`, `reply_to` or headers on an email), `unknown_kind` (400: `notify.send` of a kind that is not one — notify's own code, tokens say `unknown_capability`). Node and Python raise the two `_not_allowed` codes themselves, before any request (`channel`, `folder`, `url`, `routingKey`/`routing_key`…; `from` — Python `from_` —, `replyTo`/`reply_to`, `headers`), and any other option a call does not take is `bad_request` — on every Node call, and on Python's notify calls, never an uncoded `TypeError` — a missing required argument there (`email()` without `to`, `subject` or `text`, `html=` notwithstanding; `slack()` without text; `send()`/`deliver()`/`resolve()` without the kind) is `bad_request` naming it. Elsewhere in Python a keyword a call does not take (`jobs.start("ev", bogus=1)`, `data.set({}, bogus=1)`) is Python's own `TypeError`, not a coded refusal |
| redirects | `unexpected_redirect` in all four — message `unexpected redirect from <path>`, `status` the 3xx, hint "TOFT_API_URL should be the address Toft set for this app; a redirect usually means it points at a page behind sign-in or at the wrong host". A store redirect with no Location while reading a run's output is `unexpected_response` |

Every call gives up after 30 s in all, the resend included (object-store
transfers after 5 min), and follows
no redirect. **Every call, in all four languages, waits a `rate_limited` refusal
out** — the `Retry-After` it carried plus up to half a second of jitter, again and
again, until the call's 30 s are spent — so a burst of calls, one after another or
concurrent (a thread pool, `Promise.all`, goroutines), is paced rather than
refused: past the burst each call takes about a second, and only one still
waiting at 30 s is raised. `update` and `wait` go further and ride it out to a deadline. The app's own calls share a rate limit of 60/min (burst 10); store
signing and reading runs have their own 600/min buckets.

### The app itself, and what it may do

```python
toft.app.id, toft.app.slug, toft.app.name, toft.app.mode, toft.app.base_path
toft.app.capabilities, toft.app.policy
toft.app.can("email")          # an integration name, or a full one like "email.send"
```

Go: `toft.App.Self(ctx)` → `AppInfo{ID, Slug, Name, Mode, BasePath, …}`,
`toft.App.Can(ctx, "email")`. R: `app_info()` (cached; `refresh = TRUE`),
`app_base_path()`, check `app_info()$capabilities`.

- `id` and `slug` need the platform like every other field: off-platform they
  raise `off_platform` (Node too — never `""`).
- `mode` is **this workload's** mode, right from the first request.
- `base_path` equals `BASE_PATH` and is never `""` on a mounted app.
- `policy` is what an administrator has decided about this app, read-only. The
  fields an app acts on: `deploys_blocked` (with `blocked_reason`, present only
  while blocked) and `source_allowed` (with `source_reason`, present only while
  not allowed) say the next deploy will be refused;
  `sleeps` with `idle_sleep_minutes` (and `sleep_exemption`, present only when it does not)
  say whether an idle service is put to sleep; `integrations` lists each one
  attached, whether an administrator switched it off, and where it lands. The
  rest — `platform_memory_limit_mb`, `platform_cpu_limit_millicores`,
  `max_versions_per_app`, the `*_releases_kept` pair (`requested_releases_kept`, what
  the app asked for, and `effective_releases_kept`, what it gets) and
  `releases_kept_conflict`, `log_copy` (an object: `mode`, `capped`,
  `dropped_since_start`) — is the app page's, carried here as read and not something to
  branch on.
- **The answer is cached for the process.** An integration or storage mapping
  an administrator changes reaches the service at its **next deployment** (each
  job at its next run). Ask at startup and show "email is not enabled for this
  app" on screen rather than failing at 2am. Other capabilities to ask:
  `"viewer.identity"`, `"viewer.identity.email"`, `"sharepoint.token"`.

### Who is looking

```python
c = toft.caller(request.headers)      # signed role, verified locally, no request
c.role, c.at_least("editor"), c.is_person, c.signed_in

me = toft.who(request.headers)        # Identity, or None for nobody
if me and (me.role == "owner" or me.is_admin): ...
if me and "finance" in me.group_names: ...
```

Node `toft.caller(h).atLeast("editor")`, `await toft.who(h)` (`isAdmin`,
`groupNames`); Go `toft.CallerFor(r.Header).AtLeast(toft.RoleEditor)`,
`toft.Who(ctx, r.Header)` (`nil, nil` for nobody), `Identity.InGroup(name)`;
R `caller_role(headers)`, `caller_can(headers, "editor")`, `viewer(headers)`.

- **Caller role** is one of `owner`, `editor`, `viewer`, `anonymous`, `system`
  (a schedule firing), `app` — or `unknown` (missing, unverifiable or expired),
  which passes no `at_least`. The assertion lasts two minutes: in Streamlit,
  read it once at the top of the script.
- **`is_person` means the caller is on the person ladder** (`anonymous`,
  `viewer`, `editor`, `owner`), not that a human is there. An anonymous visitor
  is `is_person` true and `signed_in` false; a schedule firing (`system`), the
  app itself (`app`) and `unknown` are false for both. `signed_in` is above
  `anonymous` on that ladder — a machine client's account granted `viewer`
  reads true. (R has `caller_role()` and `caller_can()` only.)
- **`who`** answers `None` for an anonymous visitor, an API key, or a request
  with no act-for header at all (a health check, a job). It raises
  `viewer_identity_disabled` — a signed-in viewer on an app whose
  administrator has not turned viewer identity on — or `act_for_invalid`
  (401) when the act-for header on the request is not one Toft signed for this
  app, which only a forged or replayed header produces (hint: pass the request's
  headers through unchanged, or call without the viewer to act as the app);
  `act_for_wrong_app` (403) is a token another app received, `act_for_expired`
  (401) one past its life — ask the viewer to open the app again. Each carries a hint. Cached ~60 s — so for
  about a minute after an app turns public, `who()` can still name the person
  it last named. A `Viewer` printed (Node `String(v)`, Python `repr`, Go `String()`) names the
  person once `who()`/`identity()` has resolved them within the cache's minute —
  Node `[Viewer: Ada Lovelace (editor)]`, Python/Go `<toft.Viewer (Ada Lovelace, editor)>` —
  and otherwise says `a signed-in person; identity() says who, where viewer identity is on`
  (`this request's viewer` when the role cannot be verified); an anonymous one prints
  `an anonymous visitor; nobody is signed in`. Printing never makes a request. Node's
  `util.inspect` and `JSON.stringify` of a `Viewer` are that string.
- `role` is what the person may do to *this deployment in Toft*, not domain
  authority — put invoice rules on groups. `is_admin` is separate: `role`
  comes from ownership and grants alone, so an administrator with no grant on
  this app reads as `viewer` with `is_admin` true. Gate an administrator in with
  `role == "owner" or is_admin`; `at_least("editor")` / `caller_can()` will not
  let one through. `email` is `None` on a public app.
- **An API key carries its owner's role but no viewer.** The gateway signs the
  key owner's role onto the request — `caller()` reports it (`owner` for the
  owner's key) with `is_person` and `signed_in` true, meaning *a role on the
  person ladder* — but sends no act-for header, so `who()` is `None` and
  `viewer()` raises `no_viewer`. Use a signed-in session (`toft fetch
  --session`) to test viewer code.

### Files

| Python (Node / Go) | What it is |
|---|---|
| `toft.scratch_dir("uploads")` (`scratchDir` / `ScratchDir`) | per app, **wiped on every start, restart and redeploy**. Parts stay inside it: an absolute part, or one whose `..` climbs out, is `bad_request`. Off-platform a private `0700` `toft-scratch-<uid>/<hash>` under the temp dir, where `<hash>` is 12 hex characters of the working directory's hash — so two apps in development do not share one, and `TOFT_APP_SLUG` does not change it |
| `toft.session_scratch_dir(sid)` (`sessionScratchDir` / `SessionScratchDir`) | one browser login's corner; `sid` from the `X-Toft-Session` header. The id is hashed; empty is `bad_request` |
| `toft.new_session_id()` | for anonymous viewers (no header): mint one and keep it in **your own cookie** — never a name starting `toft_`, which the platform strips |
| `toft.mounts()` | every mapping: `name`, `kind`, `path`, `access`, `folder`, `read_only`, `mounted` (R: list elements; Go: the encoded `Mount`, with `ReadOnly()` / `Mounted()` as methods; Python: attributes, and `m.to_dict()` for the JSON form) |
| `toft.storage("reports").path` (`Storage(…).Path`) | a durable volume, resolved by name |
| `toft.store("reports").put(path, name=None)` (`Store(…).Put(path, name)`) | a file into an object store **mounted here** |
| `toft.store("reports").upload(path)` · `download(name)` · `url(name, attachment=True)` · `remove(name)` · `list(path)` | the same store over signed URLs — works mounted or not, where the install has a store signer (else `store_uploads_off`) |

**Prefer the signed-URL calls for stores.** On an install with no cluster
nothing mounts a store: its path is empty, `.path` raises (`not_mounted`; Go
`Mounted()` is false and `Put` refuses), and only `upload`/`download`/… work —
the same code runs in both modes. `write` access creates new objects only (an
existing name is `already_exists`); `url()` is a fifteen-minute link anyone
holding it can read. Go: `Upload(ctx, path, "")`, `Download(ctx, name)`,
`URL(ctx, name, attachment)`. Node: `url(name, { attachment: true })`.
R: `store_put`, `store_upload`, `store_download`, `store_url`, `store_remove`,
`store_list` — and **`file.copy()` onto a mounted store writes a zero-byte
object**; use `store_put`.

**One name can be two mounts** (the root read-only, a folder at `write`). Then a
lookup with no folder raises `ambiguous_mount`, listing them; name the folder —
`toft.storage("drop", folder="backup")` / `toft.store(…, folder=…)`, Node
`{ folder: "backup" }`, Go `StorageIn` / `StoreIn("drop", "backup")`, R
`storage("drop", "backup")`. An empty folder names the root; one that is
absolute or has a `.` or `..` segment is `invalid_name`, in all four.

**A name not mapped to this app is `not_mapped`**, listing what is — in every
language, for every operation (Go: each method of the zero `Mount` that
`Store` returns beside the error — and the volume's `Mount` it returns beside
`not_a_store` answers `not_a_store` to every signed-URL method, while `Put` — a copy onto the mount — copies into a mounted volume, as `store_put()` does in R; in Python and Node `store()` refuses a volume with `not_a_store`, and the copy is `storage(name).put()` / `mounts().find(…).put()`; R: every `store_*()` given that name but `store_put()`, which copies onto the mounted volume; the
platform's own `store_not_mapped` is reported as `not_mapped`). The fix is a
mapping on the app's Storage tab by an administrator, or a `[[storage]]` entry
in `toft.toml` from someone who may attach it — the SDK's sentence names only
the first. Off the platform (none of `TOFT_API_URL`, `TOFT_APP_ID`,
`TOFT_RUN_ID`, `TOFT_SCRATCH_DIR` set, and `TOFT_STORAGE` unset or blank)
`storage()` and `store()` raise `off_platform` instead, in all four — a
`TOFT_STORAGE='[]'` is a platform that mapped nothing, `not_mapped`; set `TOFT_STORAGE` to stand
a mount in locally.

R: `scratch_dir()` takes no argument and is not storage. A `mounts()` entry is a
list whose `$path` is `""` for a signed-URL store, so `file.path(m$path, "x")`
silently becomes `/x` — use `mount_path(m)`, which refuses `not_mounted`.

**SQLite and DuckDB belong on a volume, never a store** — a mounted store has
no locking. Open the file directly at the volume's path.

### The app's one document

```python
toft.data.get()                       # dict, or None if never written
toft.data.read()                      # Document: data, version, empty
                                      # (Node: `empty` is a getter, so JSON.stringify(doc) omits it)
toft.data.set({"period": p}, if_version=None)
toft.data.update(lambda s: s.update(runs=s.get("runs", 0) + 1))   # safe with a second writer
toft.data.clear()
```

One JSON object per app, 256 KiB, no keys or queries; survives restart,
redeploy and rollback. Writes return the document written. **Versions never
repeat**: a clear leaves a tombstone at the next version, so the first write
after it continues the count (it may skip a number), and an `if_version` read
before the clear is `version_conflict` (412). A read after a clear says what
the app can act on — `version 0`, empty, as if never written — and
`if_version=0` ("only if nothing is stored") succeeds on it, as on a document
never written. `update` re-reads on a version conflict (5 attempts,
then `version_conflict`) and waits out `rate_limited` without spending
attempts — Python, Node and Go for up to 300 s in all, honoring `Retry-After`
(Node `update(fn, { rateLimitTimeout })`, Go `toft.RateLimitTimeout`); R
waits it out for each call's 30 s, as every R call does, with no longer
budget. Past that it raises
`rate_limited` itself. Go `Data.Get/Read/Set/SetIf/Update/Clear/ClearIf(ctx…)`;
R `app_data_get()`, `app_data_read()`, `app_data_set(value, if_version)`,
`app_data_update(fn)`, `app_data_clear(if_version = NULL)` (`TRUE` when there was
a document). **R's `app_data_set` and `app_data_update` return the document** —
`list(data, version, empty = FALSE)`, as `app_data_read()` shapes it — not the
bare version number they returned before 3 November 2026. A get-then-set without
the version can lose a write. State, not a database.

### Telling someone

```python
toft.notify.slack("Ingest finished: 1,204 rows")             # Slack mrkdwn
toft.notify.slack_file("/tmp/recon.xlsx", title="Weekly reconciliation")
toft.notify.email(to=["finance@example.com"], subject="Weekly report", text=body,
                  html=None, cc=None, bcc=None, attachments=None)
toft.notify.send("teams", "Nightly load complete")           # any text integration
toft.notify.send("pagerduty", "Ingest late", severity="error", dedup_key="ingest-late")
toft.notify.resolve("pagerduty", "ingest-late")
toft.notify.deliver("sharepoint", "/tmp/recon.xlsx", name="Recon W32.xlsx")  # any file integration
send = toft.notify.status(send)       # .status, .done, .delivered, .blocked
```

- Node: same names, camelCase, `email({ to, subject, text })`.
- Go: `Notify.Slack(ctx, text)`, `SlackFile(ctx, att, SlackFileOptions{Title})` with `att, err := toft.AttachFile(path)`,
  `Email(ctx, toft.EmailMessage{To, Subject, Text})`, `Status(ctx, id)` — no
  generic `send`/`deliver`.
- **R**: `notify("slack", text = "…")`,
  `notify("email", to = "finance@example.com", subject = "…", text = body)` (`to`,
  `cc`, `bcc` take one address or several), `notify_status(send)`. No file
  uploads from R. (An R SDK from before 3 November 2026 sent a lone address as
  a string the platform refused: wrap it in `list()` there.) `notify(NULL, …)`
  is `bad_request`.

The app never names a channel, folder, sender or reply-to (those fields are
refused); the administrator's attachment decides. A send returns once accepted
and recorded; delivery happens after, and the record (`status`) is what a
workflow may rely on. Email needs a `to` (`no_recipient`), a subject and `text`
even with `html`; a `to` that is not a string or a list of strings (`None`
included) is `bad_request` before any request, and a string that is not an
address reaches the platform and is `bad_recipient` (400).

### Calling Graph or Drive directly

Where an administrator turned on **Let apps get access tokens** on the
SharePoint, OneDrive or Google Drive connection attached to the app:

```python
token = toft.access_token("sharepoint")      # value, expires_at, resource, folder
token.folder.drive_id, token.folder.item_id  # where the app was attached
client = GraphServiceClient(toft.azure_credential("sharepoint"))
```

Node `await toft.accessToken(kind)`, `toft.azureCredential(kind)`; Go
`toft.AccessToken(ctx, kind)`; R `access_token(kind)` → `tok$value`. Kinds:
`sharepoint`, `onedrive`, `gdrive` (pass `token.value` to Google's
`Credentials`). Cached per kind and refreshed five minutes before expiry. The
folder is a hint, not a fence — the token reaches all the grant does. Never log
`token.value` (the token object's printed form hides it). Refusals:
`<kind>_off` (403) when the install has no such connection, `<kind>_not_attached`
when it is not attached to this app, `<kind>_tokens_off` (403) when tokens are
not allowed on it, `unknown_capability` (400) for a kind that is not one of the
three (its hint names the kinds — pass `"sharepoint"`, never `"sharepoint.token"`), `token_too_wide` (409). `access_token("")` and Python's
`azure_credential` (Node's `azureCredential`) of anything but `sharepoint`/`onedrive` are `bad_request`.
A job may use one too.

### Background work

A job is another entrypoint of *this* app, same release, own limits and record.
Starting returns once queued. **A web handler answers with `respond(run)` and
never waits:**

```python
@app.post("/reports")
def make_report():
    me = toft.viewer(request.headers)              # act for the person clicking
    run = me.jobs.start("nightly-report", params={"region": "emea"})
    return toft.jobs.respond(run)                  # FastAPI: respond(run, request=request)
```
```js
const run = await toft.viewer(req.headers).jobs.start("nightly-report", { params: { region: "emea" } });
return toft.jobs.respond(run, req);   // a Fetch Response; in Express copy status, headers and body
```
```go
me, err := toft.ViewerFor(r.Header)
run, err := me.Jobs.Start(r.Context(), "nightly-report", toft.StartOptions{Params: params})
toft.Jobs.Respond(w, r, run)          // writes the 303/202 itself; return after it
```
```r
#* @post /reports
function(req, res) {
  run <- viewer_jobs(req) |> job_start("nightly-report", params = list(region = "emea"))
  job_respond(run)
}
```

`respond` sends a browser `303` to `run.status_url`
(`/apps/<slug>/__toft/runs/<id>`), a live status page the gateway serves —
progress, queue position, outcome — with no app code. Anything else gets `202`,
`Location` the same URL, and the run as JSON.

**`wait()` is for scripts, notebooks and job-to-job.** Every proxied request
carries `X-Toft-Request-Deadline` (five minutes by default); a `wait()` inside a
request with no timeout, or one past the deadline, is refused at once with
`would_outlive_request`. A run that had already finished when the handle was
last read is exempt: its wait returns it at once. A handle read while the run
was still going is refused all the same — read it again (`get`) first. The SDK sees the request through `viewer(headers)`, an
explicit `headers=` on the wait, or Flask's current request. A wait rides out
`rate_limited`. `respond` takes the run `start()` returned — a job name or a run
id is `bad_request`.

```python
run = toft.jobs.start("reconcile", params={"month": "2026-03"})   # as the app
run = run.wait(timeout=600)
run.succeeded, run.status, run.failure_reason, run.output(), run.output_json(), run.logs()
```

| | Python | Node | Go | R |
|---|---|---|---|---|
| start | `jobs.start(job, params=, idempotency_key=)` | `jobs.start(job, { params, idempotencyKey })` | `Jobs.Start(ctx, job, StartOptions{Params, IdempotencyKey})` | `job_start(job, params =, idempotency_key =)` |
| respond | `jobs.respond(run, request=)` | `jobs.respond(run, req)` | `Jobs.Respond(w, r, run)` | `job_respond(run, res, req)` (found in the handler's frame when left out) — in all four, a run `start` did not return (no id or no status page) is `bad_request` with nothing written |
| wait | `run.wait(timeout=, headers=)` | `run.wait({ timeoutMs, headers })` | `run.Wait(ctx, WaitOptions{Timeout, Request})` | `job_wait(run, timeout =, request =)` |
| read | `jobs.get(id)` · `jobs.list(job=, status=, limit=)` · `run = run.refresh()` (a new handle; the old one is unchanged) | `get` · `list({ job, status })` · `refresh()` | `Get` · `List(ctx, ListOptions{})` · `Refresh` | `job_get` · `job_list` · `job_refresh` |
| a person's runs | `viewer(h).jobs.mine(job=)` | `viewer(h).jobs.mine({ job })` | `me.Jobs.Mine(ctx, ListOptions{})` | `job_mine(req, job =)` |
| output, logs, stop | `output()` · `output_json()` · `logs()` · `tail()` · `cancel()` | `output()` · `outputJson()` · `logs(afterSeq)` · `tail()` · `cancel()` | `Output` · `OutputJSON(ctx, &v)` · `Logs` · `Tail` · `Cancel` | `job_output(run, json =)` · `job_logs` · `job_cancel` |

A run carries `id`, `job`, `status` (`queued`, `running`, `succeeded`, `failed`,
`timed_out`, `out_of_memory`, `cancelled`, `skipped`), `started_by` (`app`,
`viewer`, `cli`, `schedule`, `ui`), `rerun_of`, `params`, `scheduled_for`,
`deadline`, `progress`, `progress_message`, `queue_position`, `exit_code`,
`failure_reason` in words, `peak_memory_mb`, `status_url`, `logs_url`
(`/api/v1/app/job-runs/<id>/logs`, the path the app's token opens; `toft`
shows the same run with `/api/v1/apps/<app-id>/job-runs/<id>/logs`, the
path a person's key opens), `deduplicated` (always present on a start's
answer, true or false, and in `respond()`'s 202 body), `has_output` (an output
exists to fetch — false for none and for one expired), `failure_stage` on a
failure before the job's own command ran (`image_pull`, `runtime_version`,
`artifact_fetch`, `build`, `callback_unreachable`; `app_exec` when the command
could not be started or was stopped before it finished — a command that ran and
exited non-zero has no `failure_stage`, and `exit_code` and `failure_reason` say
it), `cpu_throttled_seconds` (time held at the CPU limit, absent where the
cgroup keeps no counter), `execution_mode` (`shared` or `isolated`) and
`definition_id` (the job definition's id — key on `job`, which is stable across
deploys). A person's reads (`toft job runs`) add `started_by_user`, who started
it; an app's never carry it. `done` is any status but queued/running. `rerun_of`, `scheduled_for` and `failure_reason` are null when
empty — present, in all four (R `NULL`, its run a list with `$done` too).

- **`output()` is `None` / `null` / `nil` when the run wrote nothing** (R
  `NULL`); empty bytes mean it wrote an empty output. A 404 for any other reason
  (no such run) raises. `output_json()` / `outputJson()` / `OutputJSON` answer
  `None` / `null` / `false` for no output, and raise `not_json` for an output
  written empty or not JSON — empty bytes are not JSON (Go: `ok` is `false`
  beside the error).
- `job_cancel()` in R and `cancel()` in Node return the run read again after
  the cancel; Python and Go return nothing.
- **A repeated SDK start is the same run**: a start from the app (`toft.jobs`
  or `viewer(h).jobs`) matching one in flight or finished in the last minute
  (same person, same params) returns it with `deduplicated`. That implicit
  window is the app route's alone — `toft job run` and Toft's Run button make
  a new run every time. An explicit idempotency key dedups on both, for 24 h;
  reusing one with a different job, params or `scheduled_for` is 409
  `idempotency_key_reused`.
- **A run is never retried.** A person reruns it (`toft job rerun`, or in Toft),
  which records `rerun_of`.
- **Params are the only input** — recorded and shown, so never secrets; 64 KB
  cap (413 `params_too_large`). Larger input goes to storage, and a param names
  where.
- **`toft.jobs` is the app; `toft.viewer(headers).jobs` is the person** (their
  `mine()`, `started_by: viewer`). `viewer()` raises `no_viewer` with no act-for
  header (API key, health check). An anonymous visitor carries one naming
  nobody, and every call on that viewer — start, `list`, `mine`, `get`, cancel — is refused `viewer_anonymous` (in R only `job_start()` and `job_mine()` take the viewer; `job_list()`, `job_get()` and `job_cancel()` are the app's and take none) — check the caller role
  first and use `toft.jobs`. The platform adds **no role gate**: who may press
  the button is the app's rule (`who` / `caller`).

### Inside a job

```python
run = toft.run                        # None outside a job
run.params["region"]                  # typed as declared, defaults applied
run.progress(40, "loading rows")      # the status page's bar and words
run.log("read 1,204 rows")            # error=True for stderr
run.write_output_json({"rows": 1204}) # or write_output(bytes); read back by output_json()
run.started_by, run.rerun_of, run.scheduled_for, run.deadline
```

Node `toft.run` (`progress`, `log(msg, { error })`, `writeOutput`,
`writeOutputJson`, `scheduledFor`; printed or `JSON.stringify`'d it shows no job
token and no output URL); Go `toft.CurrentRun()` (`Params(&v)`,
`Progress(ctx, pct, msg)`, `Log(msg, isError)`, `WriteOutput`,
`WriteOutputJSON`, `ScheduledFor()`, `Deadline()`; `%v`, `%+v` and
`json.Marshal` show no job token and no output URL — nor do Python's
`repr(toft.run)`, `vars(toft.run)` or anything reachable through
`dir(toft.run)`, and `pickle.dumps(toft.run)` is `bad_request` (pass `run.id`
and `run.params`); Node keeps both in private fields, out of reach of
`Object.getOwnPropertyDescriptors`; R's run holds neither); R `current_run()`,
`run_progress()`, `run_log()`, `run_write_output(data, json =)`,
`scheduled_for()`. `None`/`null`/`nil`/`NULL` outside a job, so shared code can
tell which entrypoint it is in.

- `scheduled_for` is **the instant the run is for** — the tick it fired for, in
  the schedule's zone, even when it started late, or what `toft job run --for`
  named. `None` otherwise, never *now*: a rerun of Tuesday processes Tuesday.
  Check `rerun_of` before repeating a side effect. R's `scheduled_for()` inside
  a job is a `POSIXct` carrying the zone as a whole-hour offset (`Etc/GMT+5`); a
  half-hour offset formats in UTC, with the sent text in `attr(x, "text")`. A
  run R *reads* — `job_get()`, `job_list()` — carries `scheduled_for` as that sent
  text, a character string; `as.POSIXct()` it yourself. Node's `toft.run.scheduledFor` is a `Date`,
  which holds no zone (`+05:30` prints as `Z`); `scheduledForText` is the sent
  text, offset included. A `JobRun`'s `scheduledFor` (and `scheduledForText`)
  is the text the run record carries. Python's `JobRun.scheduled_for` is an
  aware `datetime` in the offset the platform sent — the type
  `toft.run.scheduled_for` is — and `JobRun.scheduled_for_text` the sent text;
  Go's `ScheduledFor` keeps the offset as a fixed zone. Every read of a
  scheduled run — `toft job runs`, `jobs.get`, a rerun — carries the
  schedule's zone, as `TOFT_SCHEDULED_FOR` does.
- `log` is a print the runner ships to the run's log, flushed so a killed run
  keeps its last lines. **Order is kept within a stream, not across them**: the
  runner reads stdout and stderr as two pipes, so an `error=True` line can land
  before or after the plain lines printed around it.
- **A job holds no app token, no `PORT` and no request.** It may notify, use
  `toft.store(…)` (over signed URLs where not mounted) and get provider tokens.
  `who()` with no act-for header answers `None` without asking. Every other app
  call — `toft.data`, `toft.app` (its `id` and `slug` included), starting a job,
  `who` given a header — is refused `job_send_only`, whose sentence names the
  job and the run. Node is the exception for the two fields it reads from the
  environment: `app.slug` answers from `TOFT_APP_SLUG`, and `app.id` is
  `off_platform` because `TOFT_APP_ID` is the service's alone. Do it in the
  service, or write output the service reads back.

## Once it is deployed

`toft logs` is what the app printed, `toft events` what the platform noticed,
`toft status --json` what is serving and its URL. Export `TOFT_PLAIN=1` when an
agent runs them. A new app is private: `authentication required` on an anonymous
request is the app working. To reach it, send your key as
`Authorization: Bearer …` (the gateway consumes it; the app never sees it) —
the toft-cli skill has the recipe.

## The full documentation

Every page is Markdown. Index: https://docs.gettoft.com/latest/llms.txt (any
page's address with `.md` for its final `/` is the Markdown page).

| What | Where |
|---|---|
| The SDK, by topic | https://docs.gettoft.com/latest/cli/sdk/what-it-is.md |
| Every call, per language | https://docs.gettoft.com/latest/cli/reference/languages.md |
| How the build reads a repository | https://docs.gettoft.com/latest/user/build/how-detection-works.md |
| `toft.toml` | https://docs.gettoft.com/latest/user/build/toft-toml.md |
| Base paths | https://docs.gettoft.com/latest/user/build/base-paths.md |
| Jobs | https://docs.gettoft.com/latest/user/automation/jobs.md |

SDK source: `larchway-labs/toft-sdk` (Apache-2.0), one tag per Toft release.
