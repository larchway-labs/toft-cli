---
name: toft-cli
description: Deploy an app to a Toft install with `toft`, the command-line client — sign in without a browser, create an app, push the working directory, watch the build, read the logs, roll back, and run, rerun and wait for jobs. Load it whenever you are deploying to Toft, are asked to ship code to a Toft install, or hit an `toft` command that refused something. Nothing here needs Node, Python or a language toolchain on the machine you are working on — the install builds.
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
administrator creates under **Admin → Deploy keys**). A deploy-scoped deploy key
may create apps — `toft whoami` says `create apps yes` — and each one it creates
is owned by the group it names with `toft create --owner-group <name|id>`:

```bash
printf '%s' "$TOFT_KEY" | toft login --token-stdin https://toft.corp
```

**The administrator's half has a door of its own, and it is not the key.** A
key operates apps and is refused, by design, every route that decides who may do
what: storage grants and delegations, locking an app, install settings,
integrations, minting keys. Those answer `session_required`. When you hold the
built-in administrator's password, sign in with it once — it stores a **session
beside the key** — and run those calls with `--session`:

```bash
printf '%s' "$TOFT_ADMIN_PASSWORD" | toft login --password-stdin https://toft.corp   # --user admin is the default
toft api PUT admin/storage/<id>/grants --data '{"subject_type":"user","subject_id":"…","access":"overwrite"}' --session
toft api POST apps/<id>/lock --data '{"message":"…"}' --session   # the field is message; an unknown one is ignored
toft fetch / --session        # the app sees a signed-in person: who() answers with a name
```

Everything without `--session` still uses the key. The session lives the
install's session lifetime (hours, with an idle clock that `toft` keeps renewed
while you use it); when it ends, `--session` refuses with exit 3 and says to sign
in again — it never falls back to the key. `toft login --status` shows both. If
the password form answers that local sign-in is switched off, the install signs
in through SSO only and the administrator's half needs a person.

**Flags may come before or after the positional argument**, in every command:
`toft login <url> --token-stdin` and `toft link my-app --local` read the flag.
`toft link my-app --app other` names two apps and is refused, exit 2.
A word after `--` is an argument whatever it looks like. **A word no command reads is refused too**, exit 2, rather
than ignored. **A switch takes its value after `=`**: `--enabled=false`, never
`--enabled false` — the second is a bare `--enabled` (true) followed by a stray
word, and is refused by name.

**A key has a scope, and a read-scoped one cannot deploy.** The scope is fixed
when the key is minted and cannot be widened afterwards, so a read key is
replaced rather than changed. The key `toft login`'s device flow mints is always
full — there is no `--scope` — so a read key can only reach you through
`--token-stdin` or the environment, from a person who minted one in the browser.
Every GET works, and the first write comes back exit 3 with
`code: "key_read_scope"`. Ask for a full key; there is nothing to retry.

**A person holds at most ten keys, and an expired one still holds its slot.**
`toft login` does not revoke the key it replaces, so an account that signs in
often fills up: the eleventh mint — the device flow's approval or
`POST me/api-keys` — is a 409 `code: "key_limit_reached"`. Revoke a key under
*Your account → Credentials* (expired ones first); retrying will not help.

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

**Ask before you try: `toft whoami`.** It names the account and its role, the
credential (`api_key`, `deploy_key` or `session`, its scope and when it
expires), whether you can create apps, and what the install allows — uploaded
bundles, public apps, background jobs, store uploads (`store_uploads_available`:
whether `toft store` and the SDKs' signed-URL calls have a data plane here —
`uploads` beside it is about source bundles), and the interpreter versions a new
app is judged against. Every one of those is otherwise learned from a refusal, so
run it once before the first deploy. `--json` is the install's own
`/me/capabilities` document with the identity beside it.

**The skill you are reading came out of a binary.** `toft skill toft-cli` and
`toft skill toft-sdk` print the copies embedded in the `toft` on your PATH, which
describe exactly the commands it has. If this file and `toft --help` disagree,
replace this file with `toft skill toft-cli`.

## The loop

```bash
cd ~/code/my-app
toft whoami                       # what this credential and install allow
toft check                        # what a deploy would decide — no deploy
toft create --yes --link          # claim a slug, deploy this tree into it
# …edit files…
toft deploy --verify /            # push what is on disk now, then request /
toft fetch /api/health            # one request to the app, as you
toft status                       # what is serving, since when, from what — and a lock, if
                                  # an administrator placed one (--json: "lock", null when none)
toft logs --follow                # what the app said
toft events                       # what the platform noticed
toft deps                         # what the dependency policy says about it
toft rollback --yes               # back to the deployment before the serving one
                                  # (again: further back; never forward)
```

- **`toft create`** claims a name in the estate's namespace, so it says which slug
  it will take and asks first. `--yes` answers. `--link` writes
  `toft.toml`, so later commands in this directory know the app.
  `--repo <url>` creates from a repository instead and bundles nothing;
  `--subdir <folder>` with it builds one folder of a repository holding several
  apps, and the slug then defaults to the folder's name. `toft status` names the
  folder. **The argument is a directory, not a name**: `toft create my-app`
  with no `my-app/` here is exit 2 (`no_such_directory`) before anything is
  printed, and names `--app my-app` — the spelling that sets the slug.
  **A slug you name** with `--app` or in `toft.toml` that is already taken is
  refused, exit 2, `code: name_taken`; if the app is yours, `toft link <slug>`
  and `toft deploy`. A slug taken from a folder or directory name is still
  renamed (`-2`) and says so. `toft create --json` waits for the first build and
  answers like `deploy --json`; add `--no-watch` for the app document alone
  (`{app, url, deployment_id}` — `deploy` and `redeploy --no-watch --json`
  answer the same shape). A
  repository that does not exist, is private with no credential, has no such
  branch, or has no such `--subdir` folder is refused before anything is created: exit 1, `code:
  source_unavailable`. **With a deploy key, name the owning group**:
  `--owner-group <name|id>` (a deploy key belongs to nobody, so what it creates
  is a group's; `toft api GET groups` lists them). Without it the create is
  refused before the upload, exit 2, `code: owner_group_required`, and a name
  that matches no group is exit 2 `not_found`. A personal key may name one too,
  and the group owns the app instead of you.
- **`toft deploy`** bundles the working directory as it is, uncommitted edits
  included. It needs no git remote, no commit, not even a repository. It never
  creates an app — a missing link is exit 2 naming `toft link <slug>`.
  `toft link` into a `toft.toml` whose `[app]` table has no `slug` adds that
  one line under the header; a table that already names a slug is refused,
  exit 2 — edit it, or add a per-install entry with `--install`. A slug that
  does not resolve says where it was read (`.toft.toml [app]`), unless you
  typed it.
- **`toft redeploy`** rebuilds from the repository the app names and uploads
  nothing. On an uploaded app it is refused, naming `toft deploy`.
- **`toft restart --wait`** starts a stopped app and fails if it does not come up.
  `toft start` is the same call under the name that reads right when it is
  stopped; `toft stop` stops it, and says `already stopped` (`"changed": false`
  under `--json`) when there was nothing to do.
- **`toft apps`** lists the apps this credential can see, `--mine` for the ones it
  owns. It is how to find a slug you do not know.
- **`toft check`** (or `toft deploy --dry-run`) sends the bundle `toft deploy`
  would send and the install answers with the decisions a deploy makes before
  it builds: what the app is, the interpreter it would get, the jobs and the
  `toft.toml` tables nothing reads, and what unpacking removed. Nothing is
  deployed or recorded. Exit 1 when a deploy would be refused, and each
  problem carries the same `reason` key a failed deploy would. It does **not**
  check the dependency policy, the build or the start — the answer's
  `not_checked` says so — so a clean check is "these decisions pass", not "this
  will deploy". It costs an upload and saves a build. **It works before
  `toft create`**: with no app linked, or a slug nobody has claimed, it checks
  the directory as a new app, behind the same doors a create has, and so does
  `toft deploy --dry-run`. With a deploy key that includes the owner: a check
  of a new app needs `--owner-group <name|id>` as `toft create` does, and
  without it is the same exit 2 `owner_group_required`, before the upload. Its `--json` `warnings` are sentences, the same a
  deploy's result carries; `warning_details` gives each a `code`
  (`manifest_unread`) and, for a `toft.toml` key, its `table`. With no
  `[runtime] python`, a `requires-python` that excludes the install's default
  Python picks the newest one it allows (`runtime.requires_python` says so), and
  one nothing satisfies is refused as `runtime_version`. It names
  the secret-looking files the bundle carries (`including .env`) as a deploy
  does, and warns when `toft.toml` declares jobs and `toft whoami` says this
  install runs none. **It prints each job's effective limits with their
  source** — `nightly  timeout 45m (declared) · memory 512 MB (install
  default)` — and a job whose declared limit an administrator's ceiling has
  since lowered as a `limit_clamped` warning. A declaration above the ceiling,
  or a removed key, is a problem with its `code` (`limit_exceeds_ceiling`,
  `removed_key`) and a `hint` naming the line to write.
- **`--verify <path>`** on `toft deploy`, `redeploy`, `rollback` and `create`
  requests that path as you once the platform says the deploy succeeded, and
  exits 1 unless it answers 2xx or 3xx. The platform's own readiness probe only
  asks whether the process answers *something*; a page that throws on its first
  real request passes that and fails this. A 5xx or a refused connection is
  retried for `--verify-timeout` (30s); a 404 is an answer and is not. Under
  `--json` it is a `verify` object inside the one result document. **A failed
  check leaves the new release serving**: the message and `verify.next` name
  `toft rollback --yes --app <slug>`.
- **`toft env`**, **`toft visibility`**, **`toft deployments`** and **`toft
  delete`** are the app's settings and history — see Changing the app.

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
reader names, most often, or a secret-looking file the bundle carried — and
they are absent from the object when there are
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
| `toft logs` | the app's runtime log — `--follow` (prints each line once, as it arrives), `--lines` (1 or more; below that is exit 2), `--since 2h`, `--source app\|platform`. `--json` is one object per line: `at`, `source`, `stream`, `line`, and, on an isolated install, a `marker` (`workload_start`) on the one line where the platform's stored account gives way to the workload's own output — a shared install interleaves the two by time and draws no marked boundary. Piped or redirected, the app's own colour codes are removed; a terminal keeps them |
| `toft logs --deploy <id>` | one build's log instead, whole — `--lines N` makes it the last N. `--source` and `--since` are refused with it |
| `toft events` | what the platform noticed going wrong — the command to run after a restart that did not take |
| `toft status --json` | the app, the serving deployment, the app's URL, and two clocks: `serving_since` (when this release became the live one — a rollback's is recent even when its build is old) and `status_changed_at`. Absent from an older install. The text form prints `status running for 5 minutes`, `since` and `built` as separate lines |
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
the way in**, and `toft fetch` is the way to send it without holding it:

```sh
toft fetch /                    # status line, then the body (8 KiB of it)
toft fetch /api/items --json    # {url, status, headers, body, bytes, truncated}
toft fetch /api/items --method POST --data @item.json --header 'Content-Type: application/json'
toft fetch / --anonymous        # what a stranger sees
toft fetch /healthz --expect 200
```

It resolves the app's address the same way `status` does, sends your key to
that address only, and exits 1 for an answer that is not 2xx or 3xx. A `..` or
`.` segment in the path is refused before anything is sent (exit 2,
`invalid_path`): a fetch stays inside the app. It takes a path of the app, never
a URL: `https://…` is exit 2 `invalid_path` too. **The body
is bounded** at `--max-body` bytes (8192; `0` for all), so a page of minified
JavaScript does not land in your context to tell you the deploy worked. It waits
`--timeout` for the answer (60s); an endpoint slower than that is better made
asynchronous and polled than waited on. **When
the platform answers in the app's place** — a stopped, locked or crashed app
gets the gateway's 503 page — `fetch` prints the state instead of the page
(`app is stopped — toft start --app <slug>`, exit 1), and `--json` names it as
`platform_page`.

The apps gateway takes the key as a bearer credential and authorizes you
exactly as it would in a browser, which is also how to reach the app from
anything other than `toft`:

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


## Changing the app

```bash
toft env list                          # names; values that are not sensitive
toft env set DATABASE_URL=postgres://… # one or more KEY=VALUE; others are kept
toft env set API_TOKEN=… --sensitive   # write-only: never shown again
toft env unset DEBUG --restart         # --restart applies it now
toft visibility                        # private | authenticated | public
toft visibility authenticated
toft deployments list                  # newest first, * is serving
toft deployments prune --yes           # all but the serving one
toft deployments delete 4f1a2b --yes   # a unique prefix (6+ characters) is enough
toft delete my-app --yes               # the slug typed out; no undo
```

Under `--json`: `env list` rows carry `value` whenever it was shown — `""`
for an empty one — and `"sensitive": true` with no value for a write-only one.
`deployments list` is the install's answer, except that
`step_timings` is an object rather than a string holding one.

- **A deployment id can be shortened to a unique prefix of six or more
  characters** wherever one is taken — `toft deployments delete`, `toft logs
  --deploy`, `toft rollback <id>`. A prefix that matches nothing or several is
  exit 2 (`not_found`, `ambiguous_id`) naming the candidates.
- **`toft rollback` names the release now serving** — the one it restored —
  when it succeeds, in the summary and as `deployment_id` under `--json`. The
  row the platform watches the switch through is deleted on success.

- **Flags can go before or after the variables**: `toft env set A=1 --restart`
  is the same command as `toft env set --restart A=1`.
- **A name is letters, digits and underscores, not starting with a digit**, and
  `PORT`, `HOST` and `BASE_PATH` are the platform's to set. Both are exit 2
  before anything is sent (`invalid_env_name`, `reserved_env_name`).
- **An environment change applies at the next start**, not the next deploy:
  `toft restart`, or `--restart` on the same command. The document says
  `restart_needed`.
- **`toft env set` keeps every other variable**, sensitive ones included — the
  route replaces the whole map, and the command writes back what it read.
  A credential that may see the names but not the values is refused before
  anything is written (exit 3). A variable an administrator attached through a
  credential cannot be set here, and the refusal names the credential.
- **`toft visibility public`** can be refused by the install (`code:
  "public_apps_disabled"`) or by its license (`not_licensed`); `toft whoami`
  says in advance whether it is allowed.
- **A pruned deployment is no longer a rollback target.** The serving release,
  a running build and a rollback's source are never deleted.
- **`toft delete` never takes the slug from `toft.toml` or `TOFT_APP`** — it has to
  be typed — and it asks, so unattended it needs `--yes`.

## Exit codes

A contract, and the reason a failed run can be triaged without reading the log:

| | |
|---|---|
| 0 | it worked |
| 1 | the platform did the thing and it failed — a failed build, a refused scan, a failed job run — and a wait that ran out (`--timeout`, `--wait-timeout`): the work is still going on the platform, and the message names the command that follows it |
| 2 | usage or configuration — no app linked, a bad flag, an argument nothing reads, jobs not available on this install, a confirmation nothing could answer, **an app that is locked**, **a name that does not resolve** (an unknown deployment id — `deploy --watch` and `deployments delete` too — store, job or run), a param a job refuses, or a command that was removed (`removed_command`, `toft task`) |
| 3 | not authenticated, or refused — no credential, a revoked or expired key, uploads switched off, a license limit, or **the app's state refusing**: a rerun of a run still going (`run_still_open`), the serving deployment (`deployment_protected`) |
| 4 | the install did not answer |

Under `--json` an exit-2 refusal carries a `code` wherever one names the
mistake: the install's own (`not_found` for an id or store that resolves to
nothing, its validation code for a cron expression or time zone it refused), or
this client's — `manifest_invalid` for a `toft.toml` that does not parse,
`no_such_directory` for a directory argument that is not one, `env_not_set` for `toft env
unset` of a variable the app lacks, `owner_group_required` for a deploy key's
`toft create` without `--owner-group`, and for a credential the environment
misdescribes: `missing_install` (`TOFT_TOKEN` and no install named anywhere —
set `TOFT_URL`), `ambiguous_credential` (a token whose install the environment
does not name, or two tokens), `token_file_unreadable`, `ambiguous_alias`.
An exit-3 refusal of state is `"kind": "refused"` with a code: the install's,
from a 409, or this client's — `already_exists` for a store write onto an
existing name at `write` (each such item of a `store cp --json` list carries
it too) and `insufficient_access` for `toft store mv` from a store held below
`full`, refused before anything is copied. One mapping decides all of this
for every verb, so no verb answers 1 for something that never ran.

## Running unattended

Confirmations are detected, not remembered: `toft` treats the run as unattended
when `--yes` is passed, `CI` is set, or stdin is not a terminal — and then it
**refuses rather than hanging** on a question nobody can answer. Pass `--yes` to
anything that would ask (`toft create`, `toft rollback`, `toft deployments prune`).

`-q` drops the narration and keeps the answer on stdout — and never the reason one item of a `store cp`/`mv`/`rm` batch failed, or the sentence saying why a deploy failed. Under `--json` stdout is JSON only: `create` prints its URL to stderr there (it is in the result object). Table timestamps are local time with the zone named; every JSON field is UTC. `--json` is on every
command. `--no-color` (or `NO_COLOR`) for a clean log.

**A refusal is JSON too.** Under `--json` anything that exits non-zero without
having already written a result object writes one instead of leaving you to parse
English off stderr:

```json
{"error":"that key has expired","kind":"auth","code":"key_expired","exit":3,
 "retryable":false,"hint":"mint a new key — `toft login` replaces the stored one; retrying will not help"}
```

`kind` is the client's classification — `usage`, `auth`, `refused`, `unreachable`,
`locked`, `failed` — and `code` is the install's own, present only when it sent one.
**`retryable` is always there and is the field to branch on**: the install's own
answer when the refusal was the install's (a full job queue, `queue_full`, is `true` at 429; a
503 that means "this install is configured without it" is `false`), and for a
refusal `toft` made itself, `true` only when the install could not be reached —
and not then when the host name does not resolve, which a retry cannot fix. A
proxy's own 502/503/504 page in front of the install (a redeploy, a restart) is
`unreachable`, exit 4, never the page's HTML.
`hint` is the next step in the install's words, when there is one — act on it
rather than on the sentence. The sentence and the hint still go to stderr as
well. A **failed deploy is the exception**: its result object already said
everything, so there is no second document. So is a **failed `fetch`,
`check` or `--verify`**: the result document is the answer, and the exit code
says it failed.

**The install's API speaks the same envelope.** Every refusal from `toft api`,
from `curl`, or from the SDK inside your app is `{"error", "code",
"retryable", "hint"?}`. `code` is never absent — a refusal whose route named
none carries the status's name (`not_found`, `conflict`, `internal`).

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

## Jobs

A job is a command your app declares in `toft.toml` — `[jobs.<name>]` with a
`command`, and optionally a `timeout`, `memory`, `schedule`, `params` — run as a
process of its own from the same release, with its own timeout and memory limit:
a container of its own where the install has a cluster, a process on the
install's own machine where it does not. **`toft.toml` is the only place a job
is made**; there is no verb that creates, edits or deletes one, and a deploy key
ships them with the code. Jobs are on by default.

- **`toft job list`** prints each job with its schedule and zone, its
  `expect_within` window, its params (`--param region=<emea|amer|apac>`), its
  effective limits with their source — `timeout 45m (declared)`, `memory 512 MB
  (install default)`, `timeout 15m (clamped by admin, declared 45m)` — and
  where runs go. `toft job run` with no name lists the same jobs with how to
  run each.
- **`toft job run <name>`** starts a run and waits for it; the run's outcome is
  the exit code — **`--json` included**, where a run that did not succeed prints
  the run document *and then* the refusal, two lines, exit 1. While it waits it
  says where the run stands (`queued · 2nd`, `running · 4m · 40% loading
  rows`); `--follow` streams the run's log as well. `--param k=v` repeats, is
  never parsed into a command, and is held to the job's declared type and
  choices; **a required param left out is asked for** when a terminal is
  attached, offering its help and choices, and refused `param_required` (exit 2)
  when none is. `--for 2026-10-06T03:00:00+01:00` names the instant the run is
  for (a date or date-time with no offset is UTC); the run reads it as
  `TOFT_SCHEDULED_FOR`. `--idempotency-key K` makes starts carrying the same key
  within 24 hours one run (the answer says `deduplicated`). `--no-wait` returns
  the run id; `--timeout <d>` bounds the wait, and a wait that runs out is exit 1
  naming `toft job wait <id>` — the run carries on.
- **`toft job rerun <runID>`** starts a new run of the same job with the same
  params and `--for` instant, recorded as a rerun of the one named (`rerun_of`),
  and waits as `run` does. **Nothing reruns automatically** — there are no
  retries; a failed run stays failed and this is how it runs again. A run that
  has not finished is refused `run_still_open` (exit 3, hint `toft job wait`).
- **`toft job wait <runID>`** waits for a run something else started — a
  schedule, the app, a person in the browser, an earlier `--no-wait` — with the
  same output, `--follow`, `--timeout` and exit code as `run`.
- **`toft job runs [name]`** lists recent runs, of one job when named, with who
  started each (`app`, `viewer`, `cli`, `schedule`, `ui`) and the instant it was
  for; **`toft job runs <runID>`** is one run in full — status, reason, limits,
  peak memory, `rerun_of` — and the one command worth typing next. **`toft job
  logs <runID>`** is what the run printed; `--follow` keeps reading until it
  ends. **`toft job cancel <runID>`** stops one; on a run that already finished
  it says `already finished (<status>)`, exit 0, `"changed":false`. A run id may
  be the eight characters `toft job runs` prints.

**A run ends in one of six words, and the word is on the last line**:
`succeeded` is exit 0; `failed`, `timed_out`, `out_of_memory`, `cancelled` and
`skipped` are exit 1, with the reason beside it in words (`exit 3: connection
refused`, `timed out after 45m`, `stopped at 1024 MB`) and the tail of the log
printed unasked. `skipped` is a scheduled run that `overlap = "skip"` stood down
because the previous one was still going — it did no work, so it is not a
success. A full queue (`queue_full`) is exit 1 and retryable; a job the app does
not declare (`no_such_job`) or a param it refuses (`param_type`,
`param_choice`) is exit 2. Where the install cannot run jobs for this app,
`toft` says why as exit 2 (`jobs_unavailable`).

**`toft task` is gone.** Scheduled tasks were replaced by jobs: it refuses with
`removed_command` (exit 2) and names the replacement — a `[jobs.<name>]` with a
`command` and a `schedule`. **A `[tasks]` table, and `retries`,
`viewer_runnable` or `enabled` in a job, are refused** by `toft check` and the
deploy with `removed_key` and the replacement in the hint. Pausing a job's
schedule until the next deploy is done in Toft (or `PATCH
/api/v1/apps/{id}/jobs/{name}` with `{"enabled": false}`), not in `toft.toml`.

## Files: `toft store`

`toft store ls|cp|mv|mkdir|rm|put|get` moves files in and out of an app's durable store from
outside the platform, for a person holding a grant. On a bucket the transfer goes
**direct to the object store**, so an unreachable bucket is exit 4 naming that
host, while a refusal from the install is exit 3. On storage that is a directory
on the install's own host, the install carries the bytes itself and the URL is
the install's — the commands are the same either way.

**Every path is printed one way: `toft://<store>/<path>`**, folders with a
trailing slash — in `ls`, `ls -r`, `rm`, `mkdir`, `put` and the copy lines — and
every subcommand takes that form back, so the line one command prints is the line
the next one takes. A bare `toft store ls` lists what you hold: a store granted
outright as `toft://reports/`, and one granted a single folder of as
`toft://reports/2026-08/`.

```
toft store ls                              # what you can reach, and at what level
toft store ls reports                      # one level: its folders, then its objects
toft store ls toft://reports/2026-08/      # the level below
toft store get toft://reports/2026-08/q1.csv   # or: get reports 2026-08/q1.csv
toft store get toft://reports/2026-08/q1.csv -o -   # to stdout
```

Listing a level prints folders before objects, which is what makes an object
filed under a generated name reachable with `toft` alone — you do not have to know
the name to find it. `ls -r` lists everything beneath instead of one level.
`--json` is `{"folders": [...], "objects": [...]}` for both, with empty arrays
rather than `null`, and names relative to what was listed.

**A partitioned store takes writes only inside the folders apps are mapped to**,
on any backing. `toft store ls` prints them under the store's row, or says that
no folder is mapped yet and writes are refused — a level of `full` is not the
whole answer there. A write beside them is exit 3, code
`outside_mapped_folders`, naming the folders you could write in.

**Whole folders: `cp`, `mv`, `mkdir`, `rm -r`.** The store side of `cp` and `mv`
is written `toft://<store>/<path>`; the other side is a local path or a second
store path. Flags may come before or after the arguments.

```
toft store cp -r ./out toft://reports/2026/march/      # a folder's contents, up
toft store cp -r toft://reports/2026/ ./reports         # and down
toft store cp q1.csv toft://reports/finance/           # one file, under its own name
toft store mv toft://reports/draft.csv toft://reports/final.csv
toft store mkdir reports/2027                          # an empty folder
toft store rm -r --yes reports/2025/                   # a folder and everything in it
```

- **`toft store rm` resolves the store and the name before it asks**, so a store
  you cannot reach or an object that is not there is exit 2 `not_found`, and a
  folder without `-r` is exit 2 `is_a_folder` — never "deleted" over nothing,
  and never a refusal for `--yes`. `rm -r` of a single object deletes it.
- **Exit codes**: 2 for a name that does not resolve (`get` of a missing object
  is `not_found`) or a name the install will not take (`../x` is `bad_request`),
  3 for a refusal (your level, or a partitioned store's folders), 1 only when the
  transfer itself failed.
- **Every object still moves on its own signed URL**, at the level you hold on
  that object, so a folder grant narrows `-r` exactly as it narrows `put`.
  `-j N` sets transfers at once (default 4). One failure does not stop the rest;
  each is printed, and the command exits 1 naming how many.
- **`mv` is copy, then delete** — there is no rename in an object store. Each
  source goes only after its copy landed, so a move that fails partway leaves two
  copies, never none. Renaming needs `write` at the destination and `full` at the
  source, and **a move short of either is refused up front**, exit 3, before
  anything is copied. At `write`, moving or `put`ting onto a name that exists
  is refused, exit 3, and changes nothing.
- **A download never replaces a local file** unless you pass `--force` — `get`
  (with or without `-o`), `cp` and `mv` alike — and it checks the whole tree
  before transferring anything.
- **A store-to-store copy passes through your machine** (`TMPDIR`), never through
  the install.
- **A folder is a prefix.** It exists while something is under it; `mkdir` writes
  the empty marker that keeps an empty one, and a second `mkdir` reports `exists`.
- `rm -r` asks once, naming the count and size of exactly what it will delete,
  empty-folder markers included; unattended it needs `--yes`.

## The SDK before the deploy: `toft sdk vendor`

The app SDK is installed by the build, so a deployed app never needs this. What
it is for is everything before the deploy — an editor that can see the package,
and a local `go build`, `go vet` or CI run that does not fail on the import.

```
toft sdk vendor                  # language detected from the tree
toft sdk vendor --lang python
```

Under `--json`, `sdk_version` is the version the SDK declares and
`install_version` the install's (`version` is the install's too, as before).

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

- **Go** also gets a `go.work` naming the vendored module. No require line is
  added to your `go.mod` — a workspace resolves the import without one. Both
  paths ship with `toft deploy` and the platform then stands aside, because an app
  that brought its own SDK keeps it. **Ignore both in `.gitignore` or neither**:
  ignoring only `go.work` leaves a workspace on the platform naming a directory
  that did not ship, and the build fails there while working here.
- **Python**: `uv pip install -e .toft/sdk-python`. **The copy is added to
  `.gitignore`** (unless a rule already covers it), so the next deploy does not
  ship it — the platform installs its own. `--json` names the line as
  `gitignore`.
- **Node**: `"@larchway/toft": "file:.toft/sdk-node"` in `package.json`. That
  dependency is why the copy **ships** and is not ignored: the build's `npm ci`
  resolves it, and the platform then keeps the app's copy.
- **R**: `R CMD INSTALL .toft/sdk-r` into the library you develop against. Like
  Python's, the copy is added to `.gitignore` — the build installs the install's
  own `toft` package into the release's library.

Re-run it after the install is upgraded. Delete both paths to go back to the
platform's own copy.

## The escape hatch: `toft api`

`toft api <method> <path>` makes an authenticated call with the credential `toft`
already holds, and prints the install's own JSON on stdout — **a refusal's
too**, with the exit code still non-zero and no second `--json` document beside
it, so the install's `code` and `hint` are on stdout either way.

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
a path that matches no route, a 404, a 400 or a 409 `name_taken`; 3 for a
credential or permission refusal and for any other 409 — the app's state
refused; 4 when the install could not be reached; and 1 for the rest — a 5xx, a
422, a 409 that is a wait (`deploy_queued`, `already_running`). Branch on the
body's `code` for the detail; it is the platform's own JSON. A path with no leading slash is read as
relative to `/api/v1/`; one with a leading slash is sent as written, so `toft api
GET apps` and `toft api GET /api/v1/apps` are the same call. A path that matches
no route on the install is exit **2** with `route_not_found` — a usage problem
either way, whether the path was mistyped or the install is older than the verb.
A route that exists but not for that method is exit **2** with
`method_not_allowed`, and its hint names the method it takes.

**On Windows, prefer the relative form.** Git Bash and every other MSYS shell
rewrite an argument that starts with a slash into a Windows path *before* `toft`
is started, so `toft api GET /api/v1/apps` arrives as `C:/Program
Files/Git/api/v1/apps` and reaches no route. `toft` recognises the shape and says
so, but the shell is what did it: use `toft api GET apps`, which is never
rewritten, or set `MSYS_NO_PATHCONV=1`.

**Prefer a verb where one exists.** `toft api` validates nothing but your JSON: a
real verb checks the arguments, names the one you left out, reports failures in
sentences, and keeps working when the route behind it changes. Reach for `toft
api` for the rows below, not instead of `toft deploy`.

## What `toft` does not do

Be straight about this rather than inventing a flag. Everything here is reachable
with `toft api`, which is the point of the column on the right:

| | |
|---|---|
| An app's name, slug, branch, embedding origins or listing | Not in the CLI. `PATCH /api/v1/apps/{id}` with the field, or the Settings page. Environment variables and visibility have verbs: `toft env`, `toft visibility` |
| Creating, editing or deleting a job | Not a call at all: a `[jobs.<name>]` table in `toft.toml`, shipped with `toft deploy`. Pausing a schedule until the next deploy is the app's Automation tab, or `PATCH /api/v1/apps/{id}/jobs/{name}` with `{"enabled": false}` |
| A notebook's re-render schedule | Not in the CLI, and not a job — it produces a new rendered release rather than running a command. The Automation tab, or `PUT`/`DELETE /api/v1/apps/{id}/render-schedule` |
| An app's tags | Not in the CLI. `PUT /api/v1/apps/{id}/tags` with the ids of tags that already exist; creating the tags themselves is an administrator's |
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
| a job name that does not resolve (exit 2, `no_such_job`) | a name, not a run — the platform attempted nothing. `toft job list` names what exists; a job not yet in a deployed `toft.toml` does not exist. This is exit **2**, never 1: exit 1 would mean the work ran and failed |
| `run_still_open` (exit 3) on `toft job rerun` | the run has not finished; `toft job wait <id>` first, or `toft job cancel <id>` |
| `removed_key` / `limit_exceeds_ceiling` at `toft check` or deploy | a key Toft no longer reads (`retries`, `viewer_runnable`, `enabled`, `[tasks]`), or a `timeout`/`memory` above the install's ceiling. The hint is the line to write instead |
| `background jobs are not available` (exit 2, `code: jobs_unavailable`) | this install cannot run jobs for this app, and the message and the install's hint say why. Configuration, not a bug in the job |
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
