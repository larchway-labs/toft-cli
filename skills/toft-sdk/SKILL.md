---
name: toft-sdk
description: Write an app that runs on Toft — what the platform sets in its environment, how it is detected and built, what `toft.toml` declares, and the Toft app SDK for Python, Node, Go and R (`toft.app.can`, scratch and storage, the app's JSON document, Slack and email, background jobs, who the viewer is, a scheduled task's log). Load it when writing or fixing code that will be deployed to Toft, when an app works locally and misbehaves once deployed, or when an app needs to send a notification, store a file, or start background work.
---

# Writing an app for Toft

An app is ordinary code. Toft clones or receives it, works out what it is,
installs its dependencies, starts it, and puts it behind a URL. There is nothing
to import to be deployable — the SDK below is for the things only the platform
can do.

## The contract every app keeps

| | |
|---|---|
| `PORT` | listen on it. Never on a port you chose |
| `HOST` | bind it. `app.listen(port)` alone binds `0.0.0.0`, which is reachable without going through the platform |
| `BASE_PATH` | where you are mounted, e.g. `/apps/reports`. Always set, on every install and both origin shapes |

**Links and form actions carry `BASE_PATH`; redirects must not.** The proxy
strips the prefix before your handler sees the request and re-adds it on the way
out, so a `Location: /done` is right and `Location: /apps/reports/done` is
doubled. Root-absolute asset URLs (`/styles.css`) ask the *platform*, not you,
and 404.

Anything else you need — a database URL, an API key — is an environment variable
someone sets on the app's Settings page. A restart applies it; a redeploy is not
required. Your process never receives the platform's own secrets.

## How the build decides what your app is

Detected from the tree, in this order:

| | |
|---|---|
| **Next.js** | `next.config.*` or `next` in `package.json`. A `build` script is required; do **not** set `basePath` or `output` |
| **Node** | any `package.json` with a `start` script. A `build` script runs first if present |
| **Shiny** | `app.R`, or `ui.R` **and** `server.R` together. An `.Rmd` declaring `runtime: shiny` is a Shiny app, not a document |
| **plumber** | `plumber.R`, or an `.R` file carrying `#*` annotations |
| **R Markdown / Quarto** | one `.Rmd` or `.qmd` at the root, rendered once at build time and served as files |
| **Flask / FastAPI / Streamlit** | `flask` / `fastapi` / `streamlit` in `requirements.txt` |
| **Generic Python** | `requirements.txt` with no framework recognised |
| **Go** | `go.mod` plus a `main` package — module root, else the first `cmd/*`. Built into one binary |
| **Static** | last, and only when the tree has none of `package.json`, `requirements.txt`, `pyproject.toml`, `Pipfile`, `go.mod`. A `[static]` table overrides that |

Traps worth knowing before you hit them:

- **Never set `NODE_ENV=production` as an app variable.** It reaches the build,
  npm reads it as `--omit=dev`, and the build then fails on a missing dev
  dependency (`vite: command not found`). The platform sets it for the *running*
  process itself.
- **Dependency install scripts do not run** (`--ignore-scripts`), so anything
  that depended on a `postinstall` — `prisma generate`, a native rebuild —
  belongs in your `build` script.
- **npm only** for Node. A committed `package-lock.json` selects `npm ci` and
  must be in sync; a yarn or pnpm lockfile alone means versions resolve fresh at
  deploy time. The deploy is not refused, and its build log names the lockfile
  that was passed over.
- **A Go app cannot run an npm build during deploy.** Commit the built assets.
- **A frontend-only repo with a `package.json`** is not static. Either add a
  server and a `start` script, or commit the build output and declare
  `[static] root = "dist"`.
- The language version is **discovered on the install, never approximated**. A
  pin naming a patch version is refused rather than truncated; declare it once
  in the file the language already uses (`go.mod` for Go).

R has four of its own, and the first is the one that costs a deploy:

- **Commit `renv.lock`.** Without one the build installs nothing, says so, and
  the app fails at its first `library()` call. `renv::init()` then
  `renv::snapshot()`.
- **Packages arrive as binaries, and there is no compiler.** The install points
  renv at a binary repository, so a package with no build for that
  distribution fails rather than spending twenty minutes in `gcc`. Prefer a
  small lockfile: it is restored on every single deploy.
- **One document at the root.** Two `.Rmd` files is ambiguous and the deploy
  refuses, naming both. Keep helper scripts in a subdirectory — a root `.R` is
  scanned for plumber annotations, so a stray one can decide the whole
  repository's framework.
- **Do not bind a port or build a URL.** The platform starts Shiny and plumber
  by evaluating `runApp` / `pr_run` with the host and port it chose; nothing in
  your repository should read `PORT`. Shiny's assets and its WebSocket inherit
  the mount path on their own, and plumber's routes are mounted at the root —
  annotate `#* @get /summary`, never `/apps/{slug}/summary`.

Two more that are about behaviour rather than the build. **Shiny and plumber are
one R process**, single-threaded: a reactive that takes four seconds is a
four-second queue for every viewer at once, so slow work belongs in a job the
page polls for. And **a document is rendered once, at build time** — there is no
R behind the page, a re-render is a deploy rather than a restart, and whatever a
chunk prints is published to everyone who can read the page.

**A document app can still run jobs, and that surprises people.** No process
behind the page does not mean no process at all: a job is a separate container
running a command from the same release, and a document's release carries its
venv or its R library like any other. So `[jobs]` in `toft.toml` works on an
`.Rmd`, a `.qmd` and an `.ipynb`, and inside that job the SDK is fully present —
`toft.run` is populated, `toft.mounts()` answers, and the job may write to storage.
It is the one way a document app does anything after its build. What it cannot do
is see a request: no viewer identity, no task the app can observe, because
nothing here serves a request — the platform serves the rendered file.

**`static` is the exception that really has none.** A `[jobs]` table in a static
tree is refused before anything is built, with `manifest_invalid` and the reason:
a folder of files has no runtime to run a command in.

## `toft.toml`

Optional, committed, and the better door for anything it can say. Unknown
top-level tables are ignored, so it is safe to share with the CLI's `[app]` and
the platform's `[static]`.

**Ignored is not unnoticed: the build log names every table and key nothing
read.** Only `[jobs]` is read here — a `[tasks]` table declares no schedule, and
a misspelled key inside a job is a limit that stayed at its default. Neither
fails the deploy, so **check the build log rather than reading a green deploy as
proof the thing you declared exists**. Scheduled tasks are made with
`toft task create`, not from this file.

```toml
[app]
slug = "reports"              # written by `toft link`

[static]
root     = "dist"             # document root
entry    = "report.html"      # what the app's URL serves
fallback = true               # client-side routing

[jobs.nightly-report]
command  = "python -m reports.nightly"
schedule = "0 3 * * *"        # optional; omit for a job you start yourself
timezone = "Europe/London"    # optional; the schedule is UTC without it
timeout  = 1800
memory   = 1024
retries  = 2                  # off by default
expect_within = "26h"         # optional; owners are told if it goes this long without succeeding
viewer_runnable = true        # a viewer may start it

[jobs.nightly-report.params.region]
type     = "string"
required = true
```

A job declared here versions with the code it runs, and a rollback takes the
command back with it.

**A program with no web server is a batch app.** Add an empty `[batch]` table
(and `language = "python"` if the repository has more than one language's
project file): the deploy installs dependencies, starts nothing, and the app's
work is its `[jobs]`. Restart and Stop answer `no_service` on one.

**A job can send.** `toft.notify(...)` (email, Slack, any integration an
administrator attached to the app) works inside a job, with the run's own
credential; everything else on the app surface — `toft.data`, `toft.who`, starting
another job — is refused from a job with `job_send_only`. Static apps may not declare jobs — there is no runtime in
which a command would mean anything — but scheduled tasks are fine, since those
are HTTP requests to a path you published.

## The SDK

**Installed by the build, from inside the platform binary.** There is no
registry fetch and nothing to add to `requirements.txt` or `package.json`; if
you declare your own copy, yours is kept.

```python
import toft        # Python
```

```js
import toft from "@larchway/toft";   // Node — ESM. From CommonJS: await import(...)
```

```go
import "toft"     // Go — no require line; the build's go.work resolves it
```

```r
library(toft)           # R — installed into the release's renv library
                             # store_put(store("drop"), "report.parquet") to write;
                             # file.copy() to a store writes a zero-byte object
```

Off-platform every call that needs the platform raises, throws or returns an
error, naming the environment variable that is missing. **There is deliberately
no dry-run mode**: an SDK that printed to a console instead of paging a channel
would be a trap that only springs in production.

**Before the deploy, `toft sdk vendor` puts it on your disk.** The SDK is installed
by the build, so a deployed app never needs this — but until the platform has
built the app, your own tooling cannot see the package at all. In Python and Node
that is a nuisance (the import raises); in Go it is a stop, because nothing
resolves `toft` and `go build`, `go vet` and your CI all fail on the
import line.

```
toft sdk vendor                  # language detected from the tree
```

It writes `.toft/sdk-<lang>/` from the install you are signed in to, so you
compile against the copy that install's build would have used. Nothing is
published to a registry in any language, deliberately: a published package would
be a second version, and you would be building against whichever your package
manager resolved rather than against the install you deploy to.

Go also gets a `go.work` naming it — **no require line is added to your
`go.mod`**. Both paths ship with `toft deploy` and the platform then stands aside,
because an app that brought its own SDK keeps it; ignore both in `.gitignore` or
neither, since ignoring only `go.work` leaves a workspace on the platform naming
a directory that did not ship. Python and Node need one install line, which the
command prints.

### When the platform says no

Every refusal carries the platform's own sentence and three fields beside it,
and **branch on the fields, never on the sentence** — the wording is for a
person and may change.

| | Python / Node | Go | R |
|---|---|---|---|
| **`code`** — a stable name, never empty from a current install (`queue_full`, `not_found`, `app_locked`) | `err.code` | `err.Code()` | `e$code` |
| **`retryable`** — whether trying again could work | `err.retryable` | `err.Retryable()` | `e$retryable` |
| **`hint`** — the next step, when there is one (`"mint a new key"`) | `err.hint` (None / undefined) | `err.Hint()` (`""`) | `e$hint` (NULL) |

**`retryable` is the platform's decision, not the status's.** Only the handler
knows that a 503 means "this install is configured without it", which no retry
fixes, or that a 409 means "a run is in flight, wait" — the two answers a status
rule gets backwards. The SDK reports what the platform said, and falls back to
429-and-5xx only when it said nothing: a network failure, a proxy's HTML page,
an install older than the field. Log the `hint` beside the sentence; it is the
part a person reading your logs acts on.

The SDK's own single retry is narrower still: it covers a request that never
reached a handler (a rate limit, a gateway), so the platform can veto it but a
retryable 4xx is left to your loop, honoring `retry_after` / `retryAfter` /
`RetryAfter` when sent. In R the refusal is a condition of class `toft_error`,
so `tryCatch(..., toft_error = function(e) ...)` catches the platform's
refusals and nothing else; its message is unchanged.

### Go reads a little differently, on purpose

| | |
|---|---|
| **A context on everything that touches the network** | `toft.App.Can(ctx, "email")`, `toft.Notify.Slack(ctx, text)`, `toft.Jobs.Start(ctx, ...)`. Your handler already has one, and an SDK call should not be the thing in it that cannot be cancelled |
| **Errors, not exceptions** | `*toft.Error` carries the status, the platform's own words, `Code()`, `Retryable()`, `Hint()` and the decoded body. `errors.As` reaches `*toft.QueueFullError` (`InFlight`, `Limit`) and `*toft.VersionConflictError` (`Version`) |
| **Options are structs** | `toft.EmailMessage{To: …, Subject: …, Text: …}`, `toft.StartOptions{Params: …}`, `toft.SlackFileOptions{Title: …}` — Go has no keyword arguments |
| **`toft.ViewerFor(r.Header)` / `toft.Who(ctx, r.Header)`** | the first errors when there is nobody to act for; the second answers `nil, nil`, because an anonymous visitor is an answer |
| **`toft.TaskFor(r.Header)` may be nil, and a nil one still logs** | `task.Log(ctx, …)` on a nil `*toft.Task` does nothing and says so, so an endpoint serving both a schedule and a person needs no branch |
| **`toft.CurrentRun()`** | the job's view of itself, `nil` everywhere else |
| **Numbers come back as `float64`** | anything read out of `toft.Data`'s map has been through JSON. Unmarshal `Document.Data` into a struct of your own when you want your types back |

### What this app is, and what it may do

```python
toft.app.id, toft.app.slug, toft.app.mode, toft.app.base_path
toft.app.can("email")            # cheap and cached
```

`mode` is **this workload's** mode, taken from the deployment that started it —
not the app's configured setting — so it is right on the first request rather
than after the next restart.

```js
await toft.app.slug();  await toft.app.basePath();  await toft.app.can("slack");
```

**R has a smaller surface**: `app_info()` and `app_base_path()` for the app's own
facts, no `can`; `scratch_dir()` takes no argument and there is no session
scratch; `notify(kind, …)` names the kind first; `caller_role(headers)` and
`caller_can(headers, at_least)` answer the viewer's role; `mounts()`, `storage()`
and `store()`/`store_put()` match the other languages.

**In Node these are async methods, and forgetting that does not fail.**
`toft.app.id` without the call and the `await` is a Promise, and a template that
interpolates one renders `[object Promise]` — a page that looks deployed and is
wrong, on the fact an app is most likely to put in its own header. Python
exposes the same values as plain properties, so the shapes differ by language
and only one of them tells you. Run your entrypoint off-platform once before the
first deploy: it is the only check that finds this.

`base_path` / `basePath()` / `BasePath` / `app_base_path()` answers the same
value as the `BASE_PATH` variable above, and either spelling is safe to build
links from. It falls back to the variable when the install is older than the
field, so it is never `""` on an app that is mounted somewhere.

An administrator attaches an integration to an app; the app never holds the
Slack token or the mail credential and never names the channel. **Ask before you
send** — an app that checks at startup can tell someone "email is not enabled
for this app" on a screen instead of leaving it to be found at 2am in a log.

### Files

| | |
|---|---|
| `toft.scratch_dir("uploads")` / `toft.scratchDir` / `toft.ScratchDir` | ephemeral, per app, **wiped on every start, restart and redeploy** |
| `toft.session_scratch_dir(id)` / `toft.sessionScratchDir` / `toft.SessionScratchDir` | one browser session's corner of it. The id is hashed, so a traversing value cannot escape; an empty one is refused |
| `toft.storage("reports").path` / `toft.Storage(…).Path` | a durable volume an administrator mapped to this app, resolved by name |
| `toft.store("reports").put(path)` / `toft.Store(…).Put(path, name)` | a file into an object store **that is mounted here** |
| `toft.store("reports").upload(path)` · `download(name)` · `url(name)` · `remove(name)` · `list(path)` | the same store over the platform's signed URLs — in both modes, mounted or not |
| `toft.mounts()` / `toft.Mounts()` | everything mapped, with `read_only` / `ReadOnly()` |

**A store is reached over signed URLs as well as at its path, and on an install
with no cluster only that way.** There nothing mounts a store: its entry has an
empty path, `.path` raises (Go: `Mounted()` is false and `Put` refuses), and
`upload` / `download` / `url` / `remove` / `list` are how the app reaches it.
They work the same where the store *is* mounted, so code written against them
moves between execution modes unchanged. The app signs at its mapping's level —
`write` creates new objects only, and an existing name is refused by name — and
the bytes go straight to the object store. `url(name, attachment=True)` is a
fifteen-minute link to hand to a browser; anyone holding it can read the object.
Go takes a context first (`Upload(ctx, path, "")`), Node takes options objects
(`url(name, { attachment: true })`), and R has functions rather than methods:
`store_upload(store("drop"), "report.csv")`, `store_download`, `store_url`,
`store_remove`, `store_list`.

**One name can be two mounts.** A mapping's identity is
`(resource, app, folder)`, so an administrator can attach one resource twice —
the root read-only and a folder at `write`, at two paths in one workload. Both
arrive under the same name, and the folder is what tells them apart:

```python
toft.storage("drop", folder="backup").path     # toft.store(name, folder=…) likewise
```
```js
toft.storage("drop", { folder: "backup" });
```
```go
toft.StorageIn("drop", "backup")               // Go has no keyword arguments
```
```r
storage("drop", "backup")
```

A name matching two mounts **with no folder named raises**, listing what is
mounted and at what level, rather than picking one — returning the first would
answer by the alphabetical order of paths somebody else chose. Omitting the
folder means *do not care*, which is the ordinary case and is ambiguous only
when there genuinely is more than one; an empty folder names the root.

In R, `scratch_dir()` is scratch space and is **not** where storage lives. They
are two questions with two answers, and `mounts()` is how you ask the second.

### The app's one document

```python
toft.data.get()                                   # dict, or None if never written
toft.data.set({"period": period})
toft.data.update(lambda s: s.update(runs=s.get("runs", 0) + 1))   # against a second writer
```

Both writes hand back the document they wrote — `doc.data` is what you saved,
not `None` — so a caller does not need a second read to see its own change.

One JSON document per app, 256 KiB, no keys and no queries — it survives
restart, redeploy and rollback. Never-written, cleared and `{}` stay tellable
apart. It is a place for a little state, not a database.

### Telling someone

```python
toft.notify.slack("Ingest finished: 1,204 rows")
toft.notify.slack_file("/tmp/recon.xlsx", title="Weekly reconciliation")
toft.notify.email(to=["finance@example.com"], subject="Weekly report", text=body)
send = toft.notify.status(send)
```

Nothing here blocks on delivery: a send returns once the platform has accepted
and recorded it, and the record — not the message — is what a workflow may rely
on. A send never fails the request that triggered it.

### Background work

```python
run = toft.jobs.start("reconcile", params={"month": "2026-03"})   # as the app
run = run.wait(timeout=600)
run.succeeded, run.output(), run.logs()
```

A job is a different entrypoint of *this same app*, from the same release, in a
container with its own memory limit and deadline. It never blocks on the work.

Inside the job, `toft.run.scheduled_for` (Node `run.scheduledFor`, Go
`run.ScheduledFor()`, R `scheduled_for()`) is **the instant this run is for**:
the schedule tick it fired for, in the schedule's zone, even when it started
late — or the time somebody named with `toft job run --for`. It is `None` when
nobody gave one, never *now*, so a re-run of Tuesday's work processes Tuesday.

**Two objects, and which one you call is the decision.** `toft.jobs` is the app
acting as itself. `toft.viewer(request.headers).jobs` is the app acting for the
person looking at the page — attribution that would otherwise be lost by
omission. `viewer(...)` raises when there is nobody to act for.

```python
me = toft.who(request.headers)          # Identity, or None for an anonymous visitor
if me and (me.role == "owner" or me.is_admin):
    render_admin_tab()
if me and "finance" in me.group_names:
    render_approvals()
```

`who` returns `None` for a visitor who signed in nowhere, because that is an
answer. It raises for one thing only: an app an administrator has not switched
viewer identity on for.

`role` is `owner`/`editor`/`viewer` and answers *what may this person do to this
deployment in Toft* — not what they may do in your domain. A rule about
invoices belongs on `groups`. `is_admin` is separate on purpose: an
administrator has effective ownership of every app, so `role == "owner"` alone
would grant a destructive action to every administrator on the install. `email`
is `None` on a public app.

### Inside a job, inside a task

```python
toft.run                                # the job's view of itself; None elsewhere
task = toft.task(request.headers)       # a firing; None on an ordinary visit
if task:
    task.log(f"read 1,204 rows for {task.name}")
```

**A run given no payload is given no input location.** The variable is absent
rather than pointing at an object nothing wrote, so *"was I given one?"* is
answerable by looking rather than by reading and interpreting the error. A run
started with parameters alone has no input — read the parameters. Read a payload
**at the start of the run**: the link is presigned and expires, and a job that
reads its input an hour in gets a refusal about the link, which every SDK says
in those words.

**A job holds no app token, and is told why** in all four languages. A run acts
as the run; the calls it may make are the run's own, and a job reaching for the
app's credential is a design question rather than a missing variable. The one
exception is sending: a job may notify through its app's integrations, and every
other app call is refused with `job_send_only`.

A task is an HTTP request the platform makes to a path you published — it owns
no process, so `task.log(...)` is the only thing that makes that run's log
exist. Worth adding to anything that might outlive the timeout: a run that never
answers is recorded as a failure with nothing else in it.

**A task's schedule is optional, and your handler cannot tell.** A task created
with no cron expression is fired only when somebody asks — `toft task run`, the
Run now button, or your own app — and it travels the same firing path a schedule
does, so `X-Toft-Cron: 1` is set either way and `toft.task(headers)` answers
identically. Reading it means *this was a firing*, never *a schedule came
round*.

**`task.name` is the task's name, not its cron expression** (`Task.Name` in Go,
`task.name` in Node). The platform sends the name so that one endpoint serving
several tasks can tell which fired; nothing gives an app its own cron
expression.

## Once it is deployed

`toft logs` is what your app printed, `toft events` is what the platform noticed,
and `toft status` says what is serving — `--json` carries the app's URL, which is
the install's own answer and so is right whether or not deployed apps get an
origin of their own there.

A newly created app is private — an *anonymous* request to its URL answering
`authentication required` is the app working, not a failed deploy. You can still
look at it: the apps gateway takes your own key as a bearer credential and
authorizes you exactly as it would in a browser, so `curl -H "Authorization:
Bearer $TOFT_TOKEN"` and a headless browser sending the same header both
reach an app nobody has made public. The `toft-cli` skill has the whole
recipe, the browser half included. Your app never sees that header: the gateway
consumes it.

## The full documentation

| What | Where |
|---|---|
| The SDK, by topic | https://larchway-labs.github.io/toft-docs/latest/cli/sdk/what-it-is/ |
| Every call, per language (Python, Node, R, Go) | https://larchway-labs.github.io/toft-docs/latest/cli/reference/languages/ |
| How the build reads a repository | https://larchway-labs.github.io/toft-docs/latest/user/build/how-detection-works/ |
| `toft.toml` | https://larchway-labs.github.io/toft-docs/latest/user/build/toft-toml/ |
| Base paths | https://larchway-labs.github.io/toft-docs/latest/user/build/base-paths/ |
| Jobs | https://larchway-labs.github.io/toft-docs/latest/user/automation/jobs/ |

The SDK source is public at `larchway-labs/toft-sdk` (Apache-2.0), one tag per
Toft release; the copy an app runs is the one the build installs.
