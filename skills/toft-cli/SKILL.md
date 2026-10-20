---
name: toft-cli
description: Deploy an app to a Toft install with `toft`, the command-line client — sign in without a browser, create an app, push the working directory, watch the build, read the logs, roll back, and run jobs and scheduled tasks. Load it whenever you are deploying to Toft, are asked to ship code to a Toft install, or hit an `toft` command that refused something. Nothing here needs Node, Python or a language toolchain on the machine you are working on — the install builds.
---

# Deploying to Toft with `toft`

`toft` pushes a directory to a Toft install, which builds it and serves it.
**The build happens on the install, not here.** You do not need `npm`, `node`,
`pip`, `uv`, a virtualenv, a Go toolchain or an R installation on this machine
to ship a Node, Python, Go, R or static app — you need the source on disk and
this one binary.

That is what makes the whole loop available to an agent: write files, `toft
deploy`, read what the platform says, fix, deploy again.

| Platform | How |
|---|---|
| Linux x86_64, arm64 | `install.sh` |
| macOS Intel, Apple Silicon | `install.sh` |
| Windows x86_64 | download `toft_windows_amd64.exe` by hand |

On Linux and macOS:

```bash
curl -fsSL https://raw.githubusercontent.com/larchway-labs/toft-cli/main/install.sh | sh
```

On **Windows** the script refuses rather than downloading something that does
not exist. Take the binary directly and put it on your PATH:

```powershell
curl.exe -fsSLo toft.exe https://github.com/larchway-labs/toft-cli/releases/latest/download/toft_windows_amd64.exe
```

**The binaries are unsigned, and on Windows that can stop the install dead.**
With Smart App Control enforcing, `toft.exe` is refused however it was obtained —
the download is intact and matches the published checksum, and Windows blocks it
anyway for having no signature and no reputation. There is no per-file
exception: the only lever is switching Smart App Control off, which Windows
cannot reverse without a reinstall. **Do not talk anybody into that.** Report
that the install is blocked and say the fix is a signed build.

On macOS the same lack of a signature is survivable, because Gatekeeper
quarantines what a browser downloads and not what `curl` does — so the command
above works, while a binary fetched by hand from the releases page has to be
cleared before it will run.

## Signing in without a browser

`toft login <url>` on its own opens a device flow and waits for a human. That is
the wrong door for an agent. Use a personal API key (`toftu_`, which a person
creates under **Your account → Credentials**) or a deploy key (`toftd_`, which an
administrator creates under **Admin → Deploy keys**):

```bash
printf '%s' "$TOFT_KEY" | toft login --token-stdin https://toft.corp
```

**Flags come before the positional argument.** `toft login <url> --token-stdin`
is refused, exit 2 — the flag would otherwise be dropped and you would be back
in the device flow.

**A key has a scope, and a read-scoped one cannot deploy.** The scope is fixed
when the key is minted and cannot be widened afterwards, so a read key is
replaced rather than changed. The key `toft login`'s device flow mints is always
full — there is no `--scope` — so a read key can only reach you through
`--token-stdin` or the environment, from a person who minted one in the browser.
Every GET works, and the first write comes back exit 3 with
`code: "key_read_scope"`. Ask for a full key; there is nothing to retry.

There is no `--token` flag: a credential passed that way lands in shell history
and in every `ps` on the machine. The two other doors are environment variables:

| | |
|---|---|
| `TOFT_TOKEN` | the key itself — **and it is only used when `TOFT_URL` is set too** |
| `TOFT_TOKEN_FILE` | a path to read it from, for a mounted secret |

A credential and an address are one statement. A token in the environment with
the install coming from anywhere else — a stored default, `--install` — is
refused, exit 2, naming both halves. Setting both variables at once is also a
refusal, not a precedence.

`toft login --status` says who and where. `toft login --forget <install>` drops a
stored credential (`--forget-all` drops every one); it does **not** revoke the key, and the command says so.

## The loop

```bash
cd ~/code/my-app
toft create --yes --link          # claim a slug, deploy this tree into it
# …edit files…
toft deploy                       # push what is on disk now
toft status                       # what is serving, since when, from what
toft logs --follow                # what the app said
toft events                       # what the platform noticed
toft deps                         # what the dependency policy says about it
toft rollback --yes               # back to the previous release
```

- **`toft create`** claims a name in the estate's namespace, so it says which slug
  it will take and asks first. `--yes` answers. `--link` writes
  `toft.toml`, so later commands in this directory know the app.
  `--repo <url>` creates from a repository instead and bundles nothing;
  `--subdir <folder>` with it builds one folder of a repository holding several
  apps, and the slug then defaults to the folder's name. `toft status` names the
  folder.
- **`toft deploy`** bundles the working directory as it is, uncommitted edits
  included. It needs no git remote, no commit, not even a repository. It never
  creates an app — a missing link is exit 2 naming `toft link <slug>`.
- **`toft redeploy`** rebuilds from the repository the app names and uploads
  nothing. On an uploaded app it is refused, naming `toft deploy`.
- **`toft restart --wait`** starts a stopped app and fails if it does not come up.
  `toft start` is the same call under the name that reads right when it is
  stopped; `toft stop` stops it.
- **`toft apps`** lists the apps this credential can see, `--mine` for the ones it
  owns. It is how to find a slug you do not know.

## Watching a build, and reading it afterwards

`toft deploy` prints the phases live — upload, scan, deploy — and exits non-zero
if the build fails. `--logs` interleaves the build log, which is where the
framework detection, the dependency install and the language version are
narrated. **`--json` is NDJSON everywhere — one document per line, not one per
command** — so read it a line at a time; a parser expecting a single document
stops at the second. Add `--json` for NDJSON progress frames and one result object at the
end, which is the shape to parse rather than the pretty output.

**A successful deploy can still carry `warnings`.** They are the things the
platform noticed and carried on past — a table in `toft.toml` that no
reader names, most often — and they are absent from the object when there are
none, and absent from an install older than the field, which means "this install
does not report warnings" rather than "there were none".

**Read `reason` before you read anything else.** A failed deploy's result object
carries the whole failure message, a `reason` key, and the detail that goes with
that reason — so in most cases you do not need a second command:

```json
{"deployment_id":"…","app":"my-app","status":"failed","phase":"scan","step":"scan",
 "reason":"dependency_blocked","message":"REFUSED: …","dependencies":{"…":"…"}}
```

| `reason` | What it means, and what to do |
|---|---|
| `build_failed` | The build or dependency install failed. `log_tail` is in the object; `toft logs --deploy <id>` has the rest |
| `start_failed` · `not_ready` | It **built** and then would not answer. The build log ends in "Ready." and tells you nothing — read `toft logs`, the app's own output |
| `dependency_blocked` | This install's dependency policy refused named packages. The findings are in the object under `dependencies`, and `toft deps` is the same answer. **Not a bug in your code** |
| `source_blocked` | The install refuses that repository, URL or branch. Not fixable by pushing; ask an administrator |
| `unsupported_framework` | Nothing in the tree the platform knows how to serve |
| `manifest_invalid` | `toft.toml` was read and rejected. A one-file fix, and the message says which |
| `runtime_version` | The language version you declared is not available on this install |
| `source_unavailable` | The clone, the credential, or a pruned rollback target — the code could not be fetched |
| `internal_error` | The platform, not your app. Retry, then tell somebody |

A `reason` you do not recognise means the install is newer than your `toft`; treat
it as `build_failed` and read the build log. An **absent** `reason` means the
install is older than the field — it is not a category, so fall back to `phase`
and `step`.

Afterwards:

| | |
|---|---|
| `toft logs` | the app's runtime log — `--follow`, `--lines`, `--since 2h`, `--source app\|platform`. `--json` is one object per line: `at`, `source`, `stream`, `line`, and on exactly one line a `marker` |
| `toft logs --deploy <id>` | one build's log instead. `--source` and `--since` are refused with it |
| `toft events` | what the platform noticed going wrong — the command to run after a restart that did not take |
| `toft status --json` | the app, the serving release, and the app's URL |
| `toft deps --json` | the packages, the advisories, and the versions that fix a refused deploy |

## When the dependency policy refuses a deploy

Some installs will not deploy packages with known advisories. That is an
administrator's decision about the whole install, not a judgement about your
code, and **it is the one failure with a structured answer waiting for you**:

```sh
toft deps --json | jq '.refused.findings[] | {package, version, advisory_id, severity, fixed_in, path}'
```

- `fixed_in` is the version to move to. When it is empty, no fix has been
  published and upgrading is not the route.
- `path` is the chain — `my-app > webpack > lodash`. When a finding is not
  `direct`, upgrading the package it names is not something your manifest can
  do; the chain says which of *your* dependencies to bump instead.
- `mode` and `enforcing` say whether this install is actually blocking. In
  `warn` mode findings are recorded and nothing is refused.
- A waiver is per advisory, expires, and only an administrator can grant one.
  There is no permanent waiver and nothing you can do from here to bypass the
  gate — if there is no fixed version, the routes are dropping the package or
  asking an administrator.

- When an administrator grants a waiver, or the advisory feed moves,
  `POST /api/v1/apps/{id}/dependency-recheck` re-derives this app's findings
  without a deploy. It resolves nothing and installs nothing — same packages,
  same feed — so it is worth a call only when one of those two has changed.

`toft deps` needs edit access to the app: an exact package-and-version list of a
running internal tool is a target map, so a viewer cannot read it.

## Looking at the app

`toft status --json` carries `url`, and it is the install's own answer rather than
its address with a path stuck on the end — so it is right whether or not that
install serves deployed apps on a second origin.

A new app is private, and private means the same thing to a script as to a
browser: an anonymous GET answers `authentication required`. **Your own key is
the way in.** The apps gateway takes it as a bearer credential and then
authorizes you exactly as it would in a browser:

```sh
URL=$(toft status --json | jq -r .url)
curl -fsS -H "Authorization: Bearer $TOFT_TOKEN" "$URL/"
```

The gateway consumes the key and strips it: the app process never sees it, and
never learns which credential the request arrived on. An app key (`toft_…`) works
the same way for the one app it grants.

**In a headless browser** — for a screenshot, or a page that only exists after
its JavaScript has run — send the same header on every request the page makes:

```js
// Playwright
const ctx = await browser.newContext({
  extraHTTPHeaders: { Authorization: `Bearer ${process.env.TOFT_TOKEN}` },
});
// Puppeteer:  await page.setExtraHTTPHeaders({ Authorization: ... })
// CDP direct: Network.setExtraHTTPHeaders
```

It has to reach the subresources and not just the document, or the CSS and the
scripts come back refused and the app renders as broken rather than as private
— which is why the header goes on the context or the page, not on one
navigation. The same breadth is the one thing to be careful with: these APIs add
the header to *every* host the page touches, so a page that pulls a font or a
script from somewhere else would send your key there too. If the app is not
self-contained, scope it with a request interceptor.


## Exit codes

A contract, and the reason a failed run can be triaged without reading the log:

| | |
|---|---|
| 0 | it worked |
| 1 | the platform did the thing and it failed — a failed build, a refused scan, a failed job run |
| 2 | usage or configuration — no app linked, a bad flag, jobs not available on this install, a confirmation nothing could answer, **an app that is locked**, or **a name that does not resolve** |
| 3 | not authenticated, or refused — no credential, a revoked or expired key, uploads switched off, a license limit |
| 4 | the install did not answer |

## Running unattended

Confirmations are detected, not remembered: `toft` treats the run as unattended
when `--yes` is passed, `CI` is set, or stdin is not a terminal — and then it
**refuses rather than hanging** on a question nobody can answer. Pass `--yes` to
anything that would ask (`toft create`, `toft rollback`, `toft task delete`).

`-q` drops the narration and keeps the answer on stdout. `--json` is on every
command. `--no-color` (or `NO_COLOR`) for a clean log.

**A refusal is JSON too.** Under `--json` anything that exits non-zero without
having already written a result object writes one instead of leaving you to parse
English off stderr:

```json
{"error":"that key has expired","kind":"auth","code":"key_expired","exit":3}
```

`kind` is the client's classification — `usage`, `auth`, `unreachable`, `locked`,
`failed` — and `code` is the install's own, present only when it sent one. The
sentence still goes to stderr as well. A **failed deploy is the exception**: its
result object already said everything, so there is no second document.

## What goes in the bundle

`.gitignore` decides — every one in the tree, `!` negations honoured — and git
is never shelled out to, so a plain folder bundles fine. `.toftignore` adds
to it. Always dropped: `.git/`, `.hg/`, `.svn/`, `node_modules/`, `venv/`,
`.venv/`, `__pycache__/`, `*.pyc`, `.DS_Store` — and `dist/`, `build/`, `out/`,
`.next/`, `.nuxt/`, `.svelte-kit/` **only when the tree root has a
`package.json`**, since a static site's `dist/` is the deliverable.

So: do not install dependencies before deploying. They would not travel, and the
install resolves them itself.

**R is the one where that costs real megabytes.** A local `renv::restore()`
fills `renv/library/` with the whole dependency tree, and nothing above drops it
by default — an R tree has no `package.json`, so the `dist/`-style rules do not
apply. Ignore `renv/library/` and `renv/staging/` (the usual R `.gitignore`
does) and ship `renv.lock` alone; the install restores from the lockfile against
its own binary repository, and a library built on your machine would be compiled
against your distribution rather than the install's.

A bundled `.env`, `*.pem`, `id_rsa*` or `*.key` gets one dimmed warning and is
not refused — do not put secrets in the tree.

## Jobs and scheduled tasks

Two different things, and the CLI keeps them apart because the boundary is real:

- **`toft job list|run|runs|logs|cancel`** — a job runs apart from the web
  process, with its own memory limit and deadline, from the same release — in a
  container of its own on a cluster, on the install's own machine otherwise. Declare one in
  `toft.toml`. `toft job run <name>` waits by default and the run's outcome
  is the exit code — **`--json` included**, where a failed run prints the run
  document *and then* the refusal, two lines, exit 1; `--param k=v` repeats and
  is never parsed into a command. `--for 2026-10-06T03:00:00+01:00` names the
  instant the run is for (a date or date-time with no offset is UTC); the run
  reads it as `TOFT_SCHEDULED_FOR`. A job runs in a container where the
  install has a cluster and on the install's own machine where it does not;
  `toft job runs` says which, and the instant a run was for. `toft job list` prints
  each job's schedule with its zone and any `expect_within` alert window.
  Where the install cannot run jobs for an app, `toft` says why as exit 2.
- **`toft task list|create|edit|delete|run|runs|logs`** — a scheduled task is an
  HTTP request to a path your app published, in the app's own process.
  `toft task run <name>` fires one now and waits as the job verb does, and a
  `skipped` firing is exit 1 — a firing that did not happen is not a success,
  under `--json` as well. It takes no parameters *here*: a task's parameters belong to
  its schedule, because a request to a published path has nowhere else to put
  them.

  `toft task create <name> --schedule "0 9 * * *" --path /digest` is the whole of
  it; add `--timezone Europe/London` to read the schedule in a zone rather than
  UTC (it then fires once per wall-clock time through daylight saving changes); `--schedule`, `--method`, `--overlap` and `--enabled` are optional.
  **Without a schedule the task is on demand** — nothing fires it until
  `toft task run`, the Run button or the app asks for it — and `--schedule ""` on
  an edit takes a schedule away without touching the task or its history. **`toft task edit`
  sends only the fields you name**, so naming one leaves the rest alone.
  `toft task delete` asks first, because a task takes its run history with it —
  pass `--yes` where nothing can answer.

**The two are created in different places, and only one of them here.** A job is
declared in `toft.toml` and exists once the release is built — and a
`schedule` on a job there makes it a *scheduled job*, still a container of its
own, not a task. A task is a row on the app, and `toft task create` is the way to
make one. A full personal key reaches these, a **deploy key does not** — shaping
a task is configuration rather than shipping.

**A `[tasks]` table in `toft.toml` does nothing.** Only `[jobs]` is read
there. An unrecognized table is ignored rather than refused, because the file is
shared with `[app]` and `[static]` — but the deploy says so: a plain `toft deploy`
prints it, and `--json` carries a `warnings` array on the result object. You no
longer have to read the build log to find out that something was ignored.

## Files: `toft store`

`toft store ls|cp|mv|mkdir|rm|put|get` moves files in and out of an app's durable store from
outside the platform, for a person holding a grant. On a bucket the transfer goes
**direct to the object store**, so an unreachable bucket is exit 4 naming that
host, while a refusal from the install is exit 3. On storage that is a directory
on the install's own host, the install carries the bytes itself and the URL is
the install's — the commands are the same either way.

**`ls` shows folders and takes one.** A bare `toft store ls` lists what you hold:
a store granted outright by its name alone, and a store granted one folder of as
`reports/2026-08/`. That is the same spelling `ls` takes as an argument, so the
line one command prints is the line the next one takes.

```
toft store ls                    # what you can reach, and at what level
toft store ls reports            # one level: its folders, then its objects
toft store ls reports/2026-08    # the level below
```

Listing a level prints folders before objects, which is what makes an object
filed under a generated name reachable with `toft` alone — you do not have to know
the name to find it. `ls -r` lists everything beneath instead of one level.

**Whole folders: `cp`, `mv`, `mkdir`, `rm -r`.** The store side of `cp` and `mv`
is written `toft://<store>/<path>`; the other side is a local path or a second
store path. Flags go first.

```
toft store cp -r ./out toft://reports/2026/march/      # a folder's contents, up
toft store cp -r toft://reports/2026/ ./reports         # and down
toft store cp q1.csv toft://reports/finance/           # one file, under its own name
toft store mv toft://reports/draft.csv toft://reports/final.csv
toft store mkdir reports/2027                          # an empty folder
toft store rm -r --yes reports/2025/                   # a folder and everything in it
```

- **Every object still moves on its own signed URL**, at the level you hold on
  that object, so a folder grant narrows `-r` exactly as it narrows `put`.
  `-j N` sets transfers at once (default 4). One failure does not stop the rest;
  each is printed, and the command exits 1 naming how many.
- **`mv` is copy, then delete** — there is no rename in an object store. Each
  source goes only after its copy landed, so a move that fails partway leaves two
  copies, never none. Renaming needs `write` at the destination and `full` at the
  source; at `write`, moving onto a name that exists is refused and changes
  nothing.
- **A download never replaces a local file** unless you pass `--force`, and it
  checks the whole tree before transferring anything.
- **A store-to-store copy passes through your machine** (`TMPDIR`), never through
  the install.
- **A folder is a prefix.** It exists while something is under it; `mkdir` writes
  the empty marker that keeps an empty one, and a second `mkdir` reports `exists`.
- `rm -r` asks once, naming the count and size; unattended it needs `--yes`.

## The SDK before the deploy: `toft sdk vendor`

The app SDK is installed by the build, so a deployed app never needs this. What
it is for is everything before the deploy — an editor that can see the package,
and a local `go build`, `go vet` or CI run that does not fail on the import.

```
toft sdk vendor                  # language detected from the tree
toft sdk vendor --lang python
```

It writes `.toft/sdk-<lang>/` from the install you are signed in to, so the
bytes you compile against are the ones that install's build would have used, and
it prints a **build id** for the copy it wrote — twelve hex characters derived
from the SDK's own bytes rather than a declared version. The deploy log names
the copy your app was actually built with, and the two should match. On an
isolated install they can differ: the copy you vendored came from the platform
and the copy the build used came from the runner image, which is how a fix can
ship, be vendored, and still not be in the deployed app. A mismatch is a warning
in the build log naming both, never a failed deploy.
Nothing is published to a registry in any language, and that is deliberate: a
published package is a second version, and you would then be building against
whichever one your package manager resolved.
  `toft task logs <runID> --task <name>` reads one run's log; the task name is
  required because a run id alone does not say which task it belongs to.

- **Go** also gets a `go.work` naming the vendored module. No require line is
  added to your `go.mod` — a workspace resolves the import without one. Both
  paths ship with `toft deploy` and the platform then stands aside, because an app
  that brought its own SDK keeps it. **Ignore both in `.gitignore` or neither**:
  ignoring only `go.work` leaves a workspace on the platform naming a directory
  that did not ship, and the build fails there while working here.
- **Python**: `uv pip install -e .toft/sdk-python`.
- **Node**: `"@larchway/toft": "file:.toft/sdk-node"` in `package.json`.
- **R** is not vendored — the install serves the Go, Python and Node SDKs, and
  `--lang r` is refused with `sdk_language_unknown`. The build installs the R
  package into the release's library, and unlike Go there is no compile step
  here to fail without it.

Re-run it after the install is upgraded. Delete both paths to go back to the
platform's own copy.

## The escape hatch: `toft api`

`toft api <method> <path>` makes an authenticated call with the credential `toft`
already holds, and prints the install's own JSON on stdout.

```bash
toft api GET /api/v1/apps
toft api PATCH /api/v1/apps/$ID --data '{"visibility":"public"}'
toft api POST /api/v1/apps/$ID/deployments --data @body.json
cat body.json | toft api POST /api/v1/apps/$ID/cron --data @-
```

**Never read the credential out of the config file.** There is no command that
prints it, and that is deliberate — its path and format are an implementation
detail, they differ per platform, and a regex over them breaks silently the day
the format changes. `toft api` is how you make the call without ever holding the
key: it keeps the secret out of your shell variables, out of the process table,
and out of whatever captured your output.

Exit codes are the usual contract and are **coarser than the HTTP status**: 2 for
a path that matches no route, 3 for a credential or permission refusal, 4 when
the install could not be reached, and 1 for everything else the install refused —
a 400 or a 422 included, where it understood the request and said no. Branch on
the body for those; it is the platform's own JSON, and an exit code shared with
every other command cannot tell "your request was wrong" from "the platform tried
and failed". A path with no leading slash is read as
relative to `/api/v1/`; one with a leading slash is sent as written, so `toft api
GET apps` and `toft api GET /api/v1/apps` are the same call. A path that matches
no route on the install is exit **2** with `route_not_found` — a usage problem
either way, whether the path was mistyped or the install is older than the verb.

**On Windows, prefer the relative form.** Git Bash and every other MSYS shell
rewrite an argument that starts with a slash into a Windows path *before* `toft`
is started, so `toft api GET /api/v1/apps` arrives as `C:/Program
Files/Git/api/v1/apps` and reaches no route. `toft` recognises the shape and says
so, but the shell is what did it: use `toft api GET apps`, which is never
rewritten, or set `MSYS_NO_PATHCONV=1`. The same applies to `--path` on `toft task
create`.

**Prefer a verb where one exists.** `toft api` validates nothing but your JSON: a
real verb checks the arguments, names the one you left out, reports failures in
sentences, and keeps working when the route behind it changes. Reach for `toft
api` for the rows below, not instead of `toft deploy`.

## What `toft` does not do

Be straight about this rather than inventing a flag. Everything here is reachable
with `toft api`, which is the point of the column on the right:

| | |
|---|---|
| Environment variables | Not in the CLI. Set them on the app's Settings page, or `PATCH /api/v1/apps/{id}` with `env_vars`. A restart applies them; a redeploy is not required |
| Making an app public | Not in the CLI. `visibility` on the same PATCH, or the Settings page. A newly created app is private, so an *anonymous* fetch of its URL answers `authentication required` — that is the app working, not a broken deploy, and your own key fetches it (see Looking at the app) |
| Deleting an app | Not in the CLI |
| Creating, editing or deleting a scheduled task | `toft task create\|edit\|delete`, with a full personal key |
| A notebook's re-render schedule | Not in the CLI, and not a scheduled task — it produces a new rendered release rather than calling a path. The Automation tab, or `PUT`/`DELETE /api/v1/apps/{id}/render-schedule` |
| An app's tags | Not in the CLI. `PUT /api/v1/apps/{id}/tags` with the ids of tags that already exist; creating the tags themselves is an administrator's |
| Pruning old releases | Not in the CLI. `DELETE /api/v1/apps/{id}/deployments` drops every release but the serving one, and `DELETE .../deployments/{deployID}` drops one. A pruned release is no longer a rollback target |
| Grants, storage mappings, integrations | Administrator surfaces, in the UI or the API |
| Publishing from RStudio | Not `toft`'s: RStudio's *Add account* takes the install's address as a Posit Connect server, signs in through the same approval page as `toft login`, and publishes with rsconnect. Its routes are under `/__api__`; an agent deploys with `toft` |

## When something refuses

| What you see | What it is |
|---|---|
| `no app is linked in this directory` | run `toft link <slug>`, or pass `--app` |
| `that key has expired` (exit 3) | mint another; nothing client-side decides this, the install said it |
| `that key can read and not write` (exit 3, `key_read_scope`) | the key was minted read-only in the browser. A scope cannot be widened — ask for a full key. Retrying, or reading first to "warm it up", changes nothing |
| `forbidden` (exit 3, `deny_system_role`) | the account is a **viewer** on this install and publishing needs the publisher role. The install says only "forbidden" — this code is the whole diagnosis. An administrator changes a system role; there is no flag, no other command and no retry that reaches it. A **personal** key can lodge the ask — an empty `POST /api/v1/me/promotion-requests`, which notifies the administrators and answers 409 if one is already pending — and then say who has to act. A deploy key cannot, and neither can a service account |
| a license limit (exit 3) | a limit on the install, not a permission problem, and nothing already deployed has stopped |
| the deploy failed during `scan` | the dependency gate, or the archive's caps. `reason` says which, and `toft deps` has the packages |
| an app that is locked (exit 2) | an administrator, or the install's own dependency policy, has locked it. **Nothing was built**, and retrying will refuse identically until the lock is lifted |
| a task or job name that does not resolve (exit 2) | a name, not a run — the platform attempted nothing. `toft task list` and `toft job list` name what exists. This is exit **2**, never 1: exit 1 would mean the work ran and failed |
| `background jobs are not available` (exit 2) | this install cannot run jobs for this app, and the message says why. Configuration, not a bug in the job |
| `authentication required` from the app's URL | the app is private and the request carried no credential — send your key, per Looking at the app |

Everything takes `--help`.

## The full documentation

These pages are the reference this skill is the field manual for. They describe
the install's own version at `/<minor>/`; `latest/` is the newest.

| What | Where |
|---|---|
| Installing `toft` | https://larchway-labs.github.io/toft-docs/latest/cli/cli/installing/ |
| Signing in and API keys | https://larchway-labs.github.io/toft-docs/latest/cli/cli/signing-in/ |
| Deploying | https://larchway-labs.github.io/toft-docs/latest/cli/cli/deploying/ |
| Every command and flag | https://larchway-labs.github.io/toft-docs/latest/cli/cli/commands/ |
| The app SDK | https://larchway-labs.github.io/toft-docs/latest/cli/sdk/what-it-is/ |
| The user guide (deploying from git, sharing, jobs) | https://larchway-labs.github.io/toft-docs/latest/user/start/what-toft-is/ |
