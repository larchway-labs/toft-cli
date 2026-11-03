---
name: toft-cli
description: Deploy an app to a Toft install with `toft`, the command-line client — sign in without a browser, create an app, push the working directory, watch the build, read the logs, roll back, set environment variables, attach storage, move files with `toft store`, and run, rerun and wait for jobs. Load it whenever you are deploying to Toft, are asked to ship code to a Toft install, or hit a `toft` command that refused something. Nothing here needs Node, Python or a language toolchain on the machine you are working on — the install builds.
---

# Deploying to Toft with `toft`

`toft` pushes a directory to a Toft install, which builds and serves it. **The
build happens on the install**: no `npm`, `pip`, `uv`, Go or R is needed here to
ship a Node, Python, Go, R or static app — only the source and this binary. The
loop is: write files, `toft deploy`, read what the platform says, fix, repeat.

**`toft skill toft-cli` prints the copy of this skill embedded in the `toft` on
your PATH**, which describes exactly the commands it has; if this file and
`toft --help` disagree, trust that. `toft skill toft-sdk` is the app-side SDK
skill. `toft skill install` (the installer runs it) puts pointers to both in
`~/.claude/skills` and `~/.agents/skills`, so upgrading `toft` upgrades them.
Every command takes `--help`.

## Installing

Linux (x86_64, arm64) and macOS (Intel, Apple Silicon):

```bash
curl -fsSL https://raw.githubusercontent.com/larchway-labs/toft-cli/main/install.sh | sh
```

Windows x86_64 — the script refuses; download the binary and put it on PATH:

```powershell
curl.exe -fsSLo toft.exe https://github.com/larchway-labs/toft-cli/releases/latest/download/toft_windows_amd64.exe
```

**The binaries are unsigned.** On Windows with Smart App Control enforcing,
`toft.exe` is refused however it was obtained, and the only lever is switching
Smart App Control off, which Windows cannot reverse without a reinstall.
**Do not talk anybody into that.** Report that the install is blocked and that the fix is
a signed build. On macOS, `curl` downloads are not quarantined, so the command
above works; a binary fetched by browser must be cleared by Gatekeeper first.

## Signing in

`toft login <url>` alone opens a device flow that waits for a human — the wrong
door for an agent, and an unattended run (`TOFT_PLAIN`, `CI`, stdin not a
terminal) refuses it, exit 2 `unattended_login`, rather than wait. Use a key:

- a personal API key, `toftu_` (a person mints it under **Your account →
  Credentials**), or
- a deploy key, `toftd_` (an administrator mints it under **Admin → Deploy
  keys**).

```bash
printf '%s' "$TOFT_KEY" | toft login --token-stdin https://toft.corp
```

With no URL, `--token-stdin` re-keys the stored default install, and refuses
before reading anything when there is none. A signal (Ctrl-C, SIGTERM) ends a
read of stdin — `--token-stdin`, `--password-stdin`, `--from-file -`, `--data
@-` — so a pipeline that never writes does not hang.

There is no `--token` flag (it would land in shell history and `ps`). The other
doors are environment variables — and **a credential and an address are one
statement**: an environment token is used only when the install also comes from
`TOFT_URL`.

| | |
|---|---|
| `TOFT_TOKEN` | the key itself |
| `TOFT_TOKEN_FILE` | a path to read it from (a mounted secret) |

Exit 2 refusals here, each with a `code`: `missing_install` (a token and no
install named — set `TOFT_URL`), `ambiguous_credential` (a token while the
install came from somewhere else — a stored default or a different `--install`
— or both variables set), `token_file_unreadable`, `ambiguous_alias`.

`toft login --status` says who and where. `toft login --forget <install>`
(`--forget-all`) drops a stored credential; it does **not** revoke the key.

**Keys have rules worth knowing before they bite:**

- **Scope is fixed at mint.** A read-scoped key can GET everything; its first
  write is exit 3, `key_read_scope`. It cannot be widened — ask for a full key;
  nothing to retry. The device flow always mints a full key, so a read key only
  arrives via `--token-stdin` or the environment.
- **A person holds at most ten keys, expired ones included.** `toft login` does
  not revoke the key it replaces, so the eleventh mint is a 409
  `key_limit_reached`. Revoke under *Your account → Credentials*.
- **A deploy key belongs to nobody**: `toft create` with one needs
  `--owner-group <name|id>` (see below). A deploy-scoped deploy key may create
  apps, set env vars, and — only if an administrator minted it with
  `may_attach` — add `[[storage]]`.
- **A key near expiry is warned about** on stderr; unattended, replace it via
  `toft login --token-stdin` (a deploy key can only be replaced that way).

### The administrator's half: `--session`

A key operates apps and is refused, by design, every route that decides who may
do what — storage grants and delegations, locking an app, install settings,
integrations, minting keys. Those answer `session_required`. With the built-in
administrator's password, sign in once; it stores a **session beside the key**,
used only by commands given `--session`:

```bash
printf '%s' "$TOFT_ADMIN_PASSWORD" | toft login --password-stdin https://toft.corp   # --user admin is the default
toft api PUT admin/storage/<id>/grants --data '{"subject_type":"user","subject_id":"…","access":"full"}' --session
toft api POST apps/<id>/lock --data '{"message":"…"}' --session   # the field is message; an unknown one is ignored
toft fetch / --session        # the app sees a signed-in person
```

`--session` never falls back to the key. When the session has ended (its
lifetime, or the person's role or groups changed), it is exit 3 / a 401 whose
hint names `toft login --password-stdin <install>` (`session_expired`; `no_session`
when none was stored). A password sign-in answered
with a redirect is refused (exit 3) and names the address — sign in there if it
is the install's. If local sign-in is switched off, the install is SSO-only and
the administrator's half needs a person.

### Ask first: `toft whoami`

Names the account and role, the credential (`api_key`, `deploy_key` or
`session`, scope, expiry), `create apps yes|no`, and what the install allows:
uploaded bundles, public apps, background jobs (`jobs_available`), store uploads
(`store_uploads_available` — whether `toft store` and the SDKs' signed URLs have
a data plane), and the interpreter versions. Each is otherwise learned from a
refusal — run it once before the first deploy. `--json` is the install's
`/me/capabilities` with the identity beside it.

## Command-line rules

- **Flags go before or after positionals**, on every command. A word after `--`
  is always an argument.
- **The global flags may also come before the command**: `--json`, `-q`/`--quiet`,
  `--yes`, `--plain`, `--no-color`, `--session`, `--app <slug>`, `--install
  <url>` — `toft --json apps` is `toft apps --json`, `toft --app demo status` is
  `toft status --app demo`. Any other flag goes after the command.
- **A word no command reads is refused** (exit 2), not ignored. `toft link
  my-app --app other` names two apps: exit 2.
- **A boolean switch takes its value after `=`**: `--plain=false`, never `--plain
  false` (refused by name).
- **Every usage refusal carries a `code`** under `--json`: `unknown_command`
  (also when `--json` comes anywhere on the line), `no_command` (a bare `toft
  --json`), `unknown_flag`, `bad_flag` (a flag written wrong, a switch given a
  separate value), `unexpected_argument` (a stray word, or two apps named),
  `missing_argument` (a required word absent), `conflicting_flags`,
  `confirmation_required` (unattended, no `--yes`), `cancelled` (answered no),
  `file_exists` (a download onto a file, without `--force`), `is_a_directory` (`fetch -o` a folder), `invalid_source`
  (`logs --source`), `invalid_url`, `unreadable_file`, `empty_input` (nothing on
  stdin), `invalid_duration` (`--since`, `--timeout`, `--within`…),
  `invalid_time`, `invalid_param` (a `--param` not written `k=v`),
  `invalid_json` / `invalid_method` (`toft api`), `no_credential` (`login
  --forget` of an install with none stored), `nothing_to_rebuild` (`redeploy`
  of an app made from an upload that has never deployed successfully — one
  that has is rebuilt from the source last uploaded), `sdk_language_unknown`, `unknown_skill`,
  `invalid_slug`. An install that does not answer is exit 4, code
  `unreachable`. **Each carries a `hint` too** — the step to take, at worst the
  command's own `--help`.

## The loop

```bash
cd ~/code/my-app
toft whoami                       # what this credential and install allow
toft check                        # what a deploy would decide — no deploy
toft create --yes --link          # claim a slug, deploy this tree into it
# …edit files…
toft deploy --verify /            # push what is on disk now, then request /
toft fetch /api/health            # one request to the app, as you
toft status                       # what is serving, since when, from what; a lock if any
toft logs --follow                # what the app said
toft events                       # what the platform noticed
toft deps                         # what the dependency policy says
toft rollback --yes               # back one deployment (again: further back; never forward)
```

### `toft create`

Claims a slug and deploys into it; asks first, so `--yes` unattended. `--link`
writes `toft.toml` so later commands here know the app. `--json` waits for the
first build and answers like `deploy --json`; `--no-watch` returns
`{app, app_id, url, deployment_id}` at once (`deploy` and `redeploy --no-watch
--json` answer the same shape). **`app` is always the slug and `app_id` the
id**, watched or `--no-watch`, on `create`, `deploy`, `redeploy` and `rollback`
alike. (`toft status --json` is the exception: its `app` is the whole app
object, `.app.id`.)

- **The argument is a directory, not a name**: `toft create my-app` with no
  `my-app/` is exit 2 `no_such_directory`. `--app my-app` sets the slug.
- A slug you name (`--app` or `toft.toml`) that is taken: exit 2 `name_taken` —
  if it is yours, `toft link <slug>` and `toft deploy`. Longer than 54
  characters: exit 2 `slug_too_long`. Not a slug (capitals, `_`, dots): exit 2
  `invalid_slug`, naming the slug it would be. A slug derived from a folder name is
  instead renamed (`-2`) or cut to 54, and says so.
- `--repo <url>` creates from a repository (bundles nothing); `--subdir
  <folder>` builds one folder of it and defaults the slug to the folder name. A
  missing repo, branch or folder, or a private one with no credential: exit 1
  `source_unavailable`, before anything is created.
- **With a deploy key, `--owner-group <name|id>` is required** (`toft api GET
  groups` lists them): without it exit 2 `owner_group_required`, before the
  upload; an unknown name is exit 2 `not_found`. A personal key may name one
  too, and the group owns the app instead of you.
- Whatever `toft check` would refuse, create refuses at the upload with the same
  code; **a refused create leaves no app and claims no slug**. A create that
  passes the upload and fails *later* — the dependency scan, the build, the
  start — **keeps the app**, status `failed`, with its deployment and build log:
  fix the tree and `toft deploy` into it (or `toft delete` it). Only the upload's
  refusals are free.

### `toft deploy`

Bundles the working directory as it is — uncommitted edits included; no git
needed. Never creates an app: no link is exit 2 `no_app`, naming `toft link
<slug>`.

- `toft link <slug>` writes the slug into `toft.toml` (`--local` writes
  `.toft.toml`). Into an `[app]` table that already names a slug it refuses
  (exit 2 `app_already_named`) — edit it, or add a per-install entry with `--install`.
- **If `toft.toml [app] install` names the install**, deploy says so before
  uploading and does not ask: read a cloned tree's `toft.toml` before deploying
  from it.
- Refuses at the upload whatever `toft check` refuses (`manifest_invalid`,
  `runtime_version`, `limit_exceeds_ceiling`, `storage_refused`…), before any
  build; on an existing app the refused upload is still recorded as a failed
  deployment under that reason.
- `--logs` interleaves the build log; `--watch <id>` rejoins a deploy already
  running.

### `toft redeploy`, `restart`, `start`, `stop`

- **`toft redeploy`** rebuilds from the app's repository, or on an uploaded app
  from the source last uploaded — after an env change or interpreter upgrade,
  without resending the tree. Refused (naming `toft deploy`) if it never
  deployed successfully.
- **`toft restart --wait`** fails if the app does not come up; restart is the
  bounce. **`toft start` is idempotent**: a stopped app prints `started`, a
  running one is left alone and prints `already running` (`--json`: `outcome:
  "already_running"`, `action: "none"`) — so "make sure it is up" never causes
  downtime. `--json` carries `action` and `outcome` (the printed word); `status`
  is the same word — never `restarted` beside a start or an unchanged app.
  - A **document** (notebook, Quarto, R Markdown) prints `served again`: a
    changed variable reaches it at the next deploy, with a `note` saying so.
  - A **static** app prints `unchanged` (no process). `toft start` of a stopped
    static app prints `started`.
- **`toft stop`** of a stopped app says `already stopped` (`"changed": false`).

### Finding apps: `toft apps`, `toft top`

`toft apps` lists what this credential can see; `--mine` for owned by you or
your groups or granted to you (`--json`: `mine`, `owner_group_id`). `toft top`
is the same kept live on a terminal — piped, `--json` or `TOFT_PLAIN` it is
exactly `toft apps`, so an agent gains nothing from it.

### `toft check` (= `toft deploy --dry-run`)

Uploads the bundle and returns the decisions a deploy makes before building:
framework, interpreter, jobs and their effective limits, `[restart]`/`[render]`
schedules (zone and first firing), the storage plan, unread `toft.toml` tables,
what unpacking removed. Nothing is deployed. **Exit 1 when a deploy would be
refused**; each problem carries the `reason` a failed deploy would, plus `code`
and `hint` — **every problem has both**. Under `reason: manifest_invalid` the
codes are `manifest_syntax` (the file does not parse; the line is named),
`invalid_job_name`, `invalid_job_command`, `invalid_runtime`, `invalid_timeout`,
`invalid_schedule`, `invalid_timezone`, `invalid_overlap`, `invalid_notify`,
`invalid_expect_within`, `invalid_param`, `batch_and_static`, `removed_key`,
`sensitive_default`, `env_entry_invalid`…, and `manifest_invalid` itself only
for what has no finer code; an unsatisfiable pin is `runtime_version`, with a
hint.

- It does **not** check the dependency policy, the build or the start
  (`not_checked` says so): a clean check means "these decisions pass".
- **Works before `toft create`**: an unlinked or unclaimed slug is checked as a
  new app, behind the same doors — including `--owner-group` with a deploy key
  (and a group the create would refuse is refused here).
- `--json` `warnings` are sentences; `warning_details` gives each a `code`
  (e.g. `manifest_unread`) and, for a `toft.toml` key, its `table`. A skipped
  `.env` (`env_file_skipped`) and a secret-looking file that ships
  (`secret_in_bundle`) are among them, each with its `path`.
- A `toft.toml` that does not parse is a check problem too — `reason:
  manifest_invalid`, `code: manifest_syntax`, the line in the message — exit 1.
- Python: with no `[runtime] python`, a `requires-python` excluding the
  install's default picks the newest version it allows
  (`runtime.requires_python`); none satisfying it is `runtime_version`. A
  `[runtime] python` pin that `requires-python` excludes is a warning,
  `pin_excluded_by_requires_python`.
- **Pins are quoted strings at the line's own width**: `node = "22"`, `python =
  "3.13"` (or `"==3.13.*"`, `">=3.12"`). A pin of the wrong width is refused
  with the line to write instead — `node = "22.1.0"` → `"22"`, `python =
  "3.13.18"` → `"3.13"`, `python = "3"` → `"==3.*"`. An unquoted `node = 22` is
  told to quote it.
- Unknown keys under `[app]` (anything but `slug`, `install`,
  `installs.<url>.slug`, `name`) are a `manifest_unread` warning, like any unread table.
- Job limits print with their source — `nightly  timeout 45m (declared) ·
  memory 1024 MB (install default) · cpu 2 cores (install default)` — plus
  `sampled rather than held by the kernel` / `not enforced on this install`
  where the install cannot hold one. A declared limit an administrator's ceiling
  has since lowered is a `limit_clamped` warning; one above the ceiling is
  `limit_exceeds_ceiling`.
- Warns when `toft.toml` declares jobs and the install runs none; names
  secret-looking files and the skipped `.env` as a deploy does.

### `--verify <path>`

On `deploy`, `redeploy`, `rollback` and `create`: once the platform says the
deploy succeeded, request that path as you; exit 1 unless 2xx/3xx. (The
platform's readiness probe only asks whether the process answers *something*.)
A 5xx or refused connection is retried for `--verify-timeout` (30s); a 404 is
not. Under `--json` it is a `verify` object in the result. **A failed check
leaves the new release serving**: the message and `verify.next` name `toft
rollback --yes --app <slug>` — except on a **first deploy** (`toft create
--verify`, or a deploy of an app with nothing serving yet), where there is
nothing to roll back to: the message says so and `verify.next` is `toft logs
--app <slug>`.

## Reading a deploy

**`--json` is NDJSON on every command — one document per line**: progress
frames, then one result object at the end. Parse line by line. **A list is
one document per row, never an array** — `apps`, `deployments list`, `env list`, `job list`, `job
runs`, `events`, `store list`, a `store cp`/`mv` batch's items, `skill --json`
— and an empty list is no lines at all: `toft apps --json | jq -s length`.

A successful result may carry **`warnings`** (an unread `toft.toml` table, a
secret-looking file). Absent means none — or an install too old to report them.
Beside them, **`warning_details`** gives each coded warning its `code`
(`go_toolchain_fetched`, `node_version_unread`, `manifest_unread`), as `toft
check` does.

**Read `reason` first.** A failed result carries the message, `reason`, the
refusal's own `code` when it has one (`storage_unknown` under `storage_refused`,
the code `toft check` names), and the detail for that reason:

```json
{"deployment_id":"…","app":"my-app","status":"failed","phase":"scan","step":"scan",
 "reason":"dependency_blocked","message":"REFUSED: …","dependencies":{"…":"…"}}
```

| `reason` | Meaning and action |
|---|---|
| `build_failed` | Build or dependency install failed. `log_tail` is in the object; `toft logs --deploy <id>` has the rest |
| `start_failed` · `not_ready` | Built, then would not answer. The build log says nothing — read `toft logs` (the app's output) |
| `dependency_blocked` | The install's dependency policy refused named packages; findings under `dependencies`, same as `toft deps`. Not a bug in your code |
| `source_blocked` | The install refuses that repository/URL/branch. Ask an administrator |
| `unsupported_framework` | Nothing in the tree the platform knows how to serve |
| `manifest_invalid` | `toft.toml` rejected; the message says which line |
| `storage_refused` | `[[storage]]` refused; the message lists each entry and its code. Often a grant an administrator makes, not an edit — see Storage |
| `storage_revoked_during_deploy` | A delegation was revoked mid-deploy; the new release was retired, the old one still serves. Deploy again once restored |
| `runtime_version` | The declared language version is not on this install |
| `source_unavailable` | Clone or credential — the code could not be fetched |
| `disk_full` | The install's disk is full. Ask an administrator |
| `internal_error` | The platform. Retry, then report |

An unrecognised `reason`: treat as `build_failed`. An absent one (older install):
fall back to `phase` and `step`.

| Afterwards | |
|---|---|
| `toft logs` | runtime log. `--follow`, `--lines N` (≥1, else exit 2 `invalid_lines`), `--since 2h`, `--source app\|platform`. `--json`: one object per line — `at`, `source`, `stream`, `line`, and on an isolated install `marker: "workload_start"` where the platform's lines give way to the workload's. Piped, the app's colour codes are stripped; under `--json` `line` is the text without them and `raw` the line as recorded (only when it had any). `toft job logs --json` is the same, one line per document |
| `toft logs --deploy <id>` | one build's whole log; `--lines N` for the tail. Not combinable with `--source`/`--since` |
| `toft events` | what the platform noticed (`--kind`, `--severity`, `--since`) — run it after a restart that did not take. `--severity` is `error`, `warning` or `info`; `--kind` is the install's own name (`app_crashed`, `job_run_failed`, `releases_pruned`, `deploy_failed`…, not `crash`) — anything else is exit 2 `invalid_kind` / `invalid_severity` listing the valid ones |
| `toft status --json` | the app, serving deployment, `url`, `serving_since` (when this release went live — recent after a rollback), `status_changed_at`, `lock` (null when none). When the newest deploy failed while an older release serves, `latest` names it with `failure_reason` |
| `toft deps --json` | packages, advisories, and the versions that fix a refused deploy |

## When the dependency policy refuses

An administrator's install-wide decision, not a judgement of your code — and the
one failure with a structured answer:

```sh
toft deps --json | jq '.refused.findings[] | {package, version, advisory_id, severity, fixed_in, path, direct}'
```

- `fixed_in` is the version to move to; empty means no fix exists. When one
  package carries several advisories, the refusal also names the one version
  that clears them all.
- A package with no wheel for the app's Python (a new interpreter line) leaves
  the release unscanned; the refusal names the way out — pin the listed version,
  or declare an earlier Python under `[runtime]`.
- `path` is the chain (`my-app > webpack > lodash`); when not `direct`, bump the
  dependency of *yours* the chain names.
- `mode`/`enforcing`: in `warn` mode nothing is refused.
- Waivers are per advisory, expire, and only an administrator grants them. With
  no fixed version, drop the package or ask.
- After a waiver or a feed update, `POST /api/v1/apps/{id}/dependency-recheck`
  re-derives findings without a deploy (same packages, same feed — only useful
  when one of those changed).

`toft deps` needs edit access to the app.

## Looking at the app

A new app is private: an anonymous request answers `authentication required`.
`toft fetch` sends your key to the app's address (from `toft status`) without
you holding it:

```sh
toft fetch /                    # status line, then the body (8 KiB of it)
toft fetch /api/items --json    # {url, status, headers, body, bytes, truncated, redirects, final_url} — redirects [] and final_url = url when none
toft fetch /api/items --method POST --data @item.json --header 'Content-Type: application/json'
toft fetch / --anonymous        # what a stranger sees
toft fetch /healthz --expect 200
toft fetch /x/respond --no-follow   # the 303 itself
toft fetch /export.xlsx -o export.xlsx           # the whole body to a file, only on 2xx/3xx
toft fetch /export.csv -o - | wc -l              # -o - is the whole body on stdout
toft fetch /load --form kind=frs --form file=@frs.csv   # multipart; implies POST
```

- Exit 1 for an answer not 2xx/3xx. Takes a path, never a URL; `..`/`.`
  segments and `https://…` are exit 2 `invalid_path`.
- **`-o` never replaces a file without `--force`** (exit 2 `file_exists`,
  nothing asked of the app); a directory is exit 2 `is_a_directory`; `-o -
  --json` is `conflicting_flags`.
- Redirects are followed and each hop printed. A redirect off the install's apps
  address is never followed (no credential leaves).
- Body bounded at `--max-body` (8192; `0` for all); `--timeout` 60s (a
  duration, `200s`). An app that does not answer in time is exit 1, code
  `timeout`, retryable.
- **When the platform answers instead of the app** (the gateway's 503 —
  stopped, locked, building, crashed, a batch app with no pages), `fetch` says
  *the platform answered 503 in the app's place (<state>)*, exit 1 — never "the
  app answered 503". The code is the gateway's own word: `stopped` (`toft start
  --app <slug>`), `batch` (it runs jobs and serves no pages — `toft job list`),
  `building`, `deploy_failed`, `locked`, `crashed`, `sleeping`, `waking`…;
  `retryable` is true for the states that pass on their own (`building`,
  `restarting`, `waking`, `unavailable`, `moving`). Two more answers are the
  platform's, not the app's: `sign_in_required` (the gateway's 401 to a request
  with no credential — `--anonymous` on an app that is not public) and
  `run_page` (the gateway's **404** for `/__toft/runs/<id>` naming no run you
  may see). A run page that exists is printed like any page, with
  `platform_page: "run_page"` under `--json`; `/__toft/runs/` with no id is
  the app's own path. Under `--json` the result document names it
  `platform_page` and the refusal document follows it.

From anything else, the apps gateway takes the key as a bearer token, authorizes
as it would a browser, and strips it before the app sees the request:

```sh
URL=$(toft status --json | jq -r .url)
curl -fsS -H "Authorization: Bearer $TOFT_TOKEN" "$URL/"
```

**Headless browser**: put the header on the context, not one navigation, or
subresources are refused and the app renders broken:

```js
const ctx = await browser.newContext({                     // Playwright
  extraHTTPHeaders: { Authorization: `Bearer ${process.env.TOFT_TOKEN}` },
});
// Puppeteer: page.setExtraHTTPHeaders(...)   CDP: Network.setExtraHTTPHeaders
```

These APIs send the header to *every* host the page touches; if the app loads
from other hosts, scope it with a request interceptor.

## Changing the app

```bash
toft env list                          # names; values that are not sensitive
toft env set API_TOKEN=…               # one or more KEY=VALUE; others are kept
toft env set API_TOKEN=… --sensitive   # write-only
toft env set --from-file .env          # every line of a dotenv file; - is stdin
toft env set --from-file .env --only-missing  # fill only empty variables
toft env set OLD_TOKEN=                # clears it in place
toft env unset DEBUG                   # removes it
toft restart                           # an env change applies at the next start
toft visibility                        # private | authenticated | public
toft visibility authenticated
toft hostname reports.example.com --on # admin only: the app at its own hostname's root
toft hostname --off                    # back to /apps/<slug>; --clear forgets the name
toft deployments list                  # newest first, * is serving
toft deployments prune --yes           # all but the serving one
toft deployments delete 4f1a2b --yes   # a unique prefix (6+ characters) is enough
toft delete my-app --yes               # the slug typed out; no undo
```

**Environment**

- **Applies at the next start** — `toft restart`. (`--restart` on `env set` is
  gone: exit 2 `removed_flag`.) A **document** app reads it at render, so the
  next deploy (`--json`: `redeploy_needed`); a **static** app reads nothing
  (`--json`: `note`).
- New variables are visible unless `--sensitive`. Without `--sensitive` or
  `--visible` an existing variable keeps its flag; with either, every variable
  set takes it. A write-only value is made visible only by resending it with
  `--visible`.
- `env set` touches only the variables it names and is all-or-nothing.
  `KEY=VALUE` operands override `--from-file`; a malformed file line is exit 2
  `invalid_env_file`. `--only-missing` fills empty variables only and reports
  the rest as *kept*. A file mixing secrets and settings is two calls.
- `SECRET=` clears in place (*cleared*; reads `not set`); `env unset` removes —
  unsetting one the app lacks is exit 2 `env_not_set`. A no-op says `nothing
  changed`.
- **Do not set `NODE_ENV=production`**: an app variable reaches the build too,
  where npm then skips devDependencies and a Node build fails on the missing one
  (`vite: command not found`). The platform already sets it for the running
  app. `toft env set` accepts it and warns on stderr (`warnings` under
  `--json`); `toft env unset NODE_ENV` removes it.
- Names: letters, digits, underscore, not starting with a digit; `PORT`, `HOST`,
  `BASE_PATH` are the platform's. Exit 2 `invalid_env_name` /
  `reserved_env_name`.
- A variable an administrator attached through a credential cannot be set here
  (the refusal names it). A read-only key may not set (exit 3).
- `env list --json` rows carry `value` (`""` when empty), or `"sensitive": true`
  with no value; a write-only one holding nothing adds `"unset": true`.
- **`[env]` in `toft.toml` declares what the app needs**: `DB_HOST =
  "db.internal"` (or `{ default = "…" }`) visible with a default, `{}` visible
  with none, `DB_PASSWORD = { sensitive = true }` a secret. Each deploy adds
  missing ones; it never changes or removes existing ones. Refusals:
  `sensitive_default` (a secret with a default), `env_entry_invalid`,
  `invalid_env_name`, `reserved_env_name`. Send secrets with `toft env set
  --from-file`.

**Settings and history**

- **`toft hostname`** is an administrator's. On/off or a rename is a *move*: a
  `triggered_by: move` deployment rebuilds the running code at the new address;
  the old address serves until it finishes, then 308-redirects. `public_url` is
  where it answers now. Refusals: `invalid_hostname` (under or a parent of the
  install's host), `hostname_taken`. DNS must already point at the apps address.
- **`toft visibility public`** can be refused by the install
  (`public_apps_disabled`) or the license (`not_licensed`); `toft whoami` says in
  advance.
- **Deployment ids** take a unique prefix of 6+ characters everywhere
  (`deployments delete`, `logs --deploy`, `rollback <id>`); none or several is
  exit 2 `not_found` / `ambiguous_id`, and `invalid_id` for one under 6.
- **`toft rollback`** names the release it restored (`deployment_id` under
  `--json`, on the result and on every progress frame; the platform's own
  short-lived rollback row is `watched_id` on those frames).
- **How far back you can roll is what retention keeps.** By default an app keeps
  **3 versions, the serving one included** — so two to roll back to. The owner
  changes the number ("Deployments to keep", `releases_kept` on `PATCH
  /api/v1/apps/{id}`) or turns cleanup off (`auto_delete_releases`); an
  administrator may cap it (`max_versions_per_app`). The app's read carries
  both: `releases_kept` is what the owner stored (`0` = never set), and
  `effective_releases_kept` is what a deploy keeps. Each deploy that retires
  older versions records a silent `releases_pruned` event naming them — `toft
  events --kind releases_pruned` answers "where did that version go".
- **A pruned deployment is no longer a rollback target**: `toft rollback <its
  id>` is exit 2 `not_found` (the row is gone), and exit 1 `gone` when the row
  stands but its release files do not. `toft rollback` with nothing older to
  go to is exit 2 `nothing_older`. The serving release, a
  running build, a rollback's source and a release pinned by an unfinished job
  run are never deleted; `prune` prints `kept <id6>: <reason> — <remedy>`
  (`kept: [{id, reason, remedy}]` beside `deleted`). Deleting the serving one is
  exit 3 `deployment_protected`; a job-pinned one says to wait for or cancel the
  run.
- **`toft delete` never takes the slug from `toft.toml` or `TOFT_APP`** — type
  it — and needs `--yes` unattended.

## Exit codes

| | |
|---|---|
| 0 | it worked |
| 1 | the platform did the thing and it failed — a failed build, refused scan, failed job run, a fetch the platform answered in the app's place — or a wait that ran out (`--timeout`, `--wait-timeout`; the work continues and the message names the command that follows it; `wait_timeout` / `timeout`, retryable) |
| 2 | usage or configuration — no app linked, a bad flag, a stray argument, a confirmation nothing could answer, **a locked app**, **a name that does not resolve** (deployment id, store, job, run), a param a job refuses, a removed command or flag (`removed_command`, `removed_flag`) |
| 3 | not authenticated, or refused — no/revoked/expired credential, uploads off, a license limit, jobs unavailable here (`jobs_unavailable`), or **the app's state refusing** (a 409 that is not a taken name or a wait): `run_still_open`, `deployment_protected`, `idempotency_key_reused` |
| 4 | the install did not answer |

## Running unattended

**An agent sets `TOFT_PLAIN=1`** (or `--plain`). An agent on a pty looks like a
person to `toft` — drawn tables, live trees, prompts. Plain mode answers exactly
as piped, with no colour, and every question refuses naming its flag.
`--plain=false` overrides it for one command.

Without it, a run is unattended when `--yes` is passed, `CI` is set, or any
stream is not a terminal — and then it **refuses rather than hangs**. Pass
`--yes` to anything that asks (`create`, `rollback`, `deployments prune`,
`delete`, `store rm -r`). Only a person on a full terminal is asked questions —
a missing required `--param`, or a pick-list of apps for a read command in an
unlinked directory (never for `deploy` or `check`).

- `--json` is on every command; stdout is then JSON only. JSON times are UTC.
- `-q` drops narration but keeps the answer, and never drops why a deploy or a
  `store` batch item failed.
- `--no-color` / `NO_COLOR` for a clean log.

**A refusal is JSON too.** Under `--json`, anything exiting non-zero without a
result object writes one:

```json
{"error":"that key has expired","kind":"auth","code":"key_expired","exit":3,
 "retryable":false,"hint":"mint a new key — `toft login` replaces the stored one; retrying will not help"}
```

- `kind`: `usage`, `auth`, `refused`, `unreachable`, `locked`, `failed`.
  `code`: the install's or the client's, present when there is one.
- **`retryable` is always present — branch on it.** It is the install's answer
  for the install's refusals (a full job queue, `queue_full`, is `true` at 429; a
  503 meaning "not configured here" is `false`); for the client's own, `true`
  only when the install was unreachable (not when the host does not resolve). A
  proxy's 502/503/504 page is `unreachable`, exit 4.
- `hint` is the next step — act on it. The sentence also goes to stderr.
- **No second document** for a failed deploy, `fetch`, `check` or `--verify`:
  the result document is the answer and the exit code says it failed. The
  exceptions are a fetch the platform answered in the app's place (the result,
  then a refusal coded with the state) and an unsuccessful `toft job run` (the
  run, then a refusal coded with how it ended) — each refusal's `hint` is the
  next command (`toft start`, `toft job logs <id>`, `toft job rerun <id>`).
- Client-side codes include `manifest_invalid` (toml does not parse),
  `no_such_directory`, `env_not_set`, `owner_group_required`, the credential
  codes above, `not_signed_in` / `no_install` (no credential for that install),
  `no_session` / `session_expired` (`--session` with none, or one that ended),
  the usage codes under Command-line rules, `invalid_visibility`,
  `invalid_kind` / `invalid_severity` (`toft events`), `wait_timeout` (a job
  wait that ran out, retryable), `timeout` (`fetch --timeout`, retryable),
  `interrupted` (a signal while stdin was read — nothing was sent, exit 1), and
  for `toft store`: `already_exists`, `insufficient_access`, `is_a_folder`,
  `no_store`, `conflicting_flags`.

**The install's API speaks the same envelope**: every refusal from `toft api`,
`curl` or the SDK is `{"error", "code", "retryable", "hint"?}`, and `code` is
never absent (`not_found`, `conflict`, `internal` when the route named none).

## What goes in the bundle

Every `.gitignore` in the tree decides (with `!` negations; git is not needed),
plus `.toftignore`. Always dropped: `.git/`, `.hg/`, `.svn/`, `node_modules/`,
`venv/`, `.venv/`, `__pycache__/`, `*.pyc`, `.DS_Store` — and `dist/`, `build/`,
`out/`, `.next/`, `.nuxt/`, `.svelte-kit/` **only when the root has a
`package.json`** (a static site's `dist/` is the deliverable).

- **Do not install dependencies before deploying** — the install resolves them.
- **R**: a local `renv::restore()` fills `renv/library/`, which nothing drops.
  Ignore `renv/library/` and `renv/staging/` and ship `renv.lock` alone.
- **`.env` and `.env.*` never go**, whatever the ignore files say
  (`.env.example`/`.env.sample` do). You see `not uploading .env — toft env set
  --from-file .env sends its values`. Bundled `*.pem`, `id_rsa*`, `*.key` get a
  warning, not a refusal — keep secrets out of the tree.

## Jobs

A job is `[jobs.<name>]` in `toft.toml` — `command`, optionally `timeout`
(`"15m"`, `"2h"`, `"7d"`, or whole seconds; 1 second to 7 days), `schedule`,
`params` — run as its own process from the same release. A declared `float`
param reaches the job as a float (`2.0`), whether sent as `"2"`, `2` or a
default. **`toft.toml`
is the only place a job is made** (no verb creates, edits or deletes one; a
deploy key ships them with the code). The timeout is yours; memory and CPU are
an administrator's (install default, or a per-job override on the app's
Automation tab that survives deploys). `memory`/`cpu` keys, `retries`,
`viewer_runnable`, `enabled` and a `[tasks]` table are refused `removed_key`,
the hint naming the replacement. **`toft task` is gone** (exit 2
`removed_command`): use a `[jobs.<name>]` with a `schedule`.

- **`toft job list`** — each job's schedule and zone, `expect_within`, params
  (`--param region=<string>  required, one of emea|amer|apac`; `--json`:
  `params`, `{}` when none), effective
  limits with source (`declared`, `install default`, `override`, `clamped by
  admin, declared 45m`) and enforcement (`--json`: `value`, `source`,
  `enforcement` = `enforced|sampled|not_enforced`). While the app is locked a
  schedule shows `held by the app's lock` (`held_by_lock: true`, no
  `next_run_at`). `toft job run` with no name lists the same. Under `--json` a
  scheduled job's `schedule` is the bare expression with `timezone` beside it
  (`UTC` when undeclared), and `expect_within_sec` / `expect_within` (`"26h"`)
  are on every row, `null` when undeclared; `paused` (the schedule switched
  off in the UI until the next deploy) and `params_spec` (the same as
  `params`, the install's own name) too.
- **`toft job run <name>`** starts a run and waits; **the run's outcome is the
  exit code**. With `--json`, an unsuccessful run prints the run document *then*
  the refusal (two lines, exit 1; `code` is the ending). `--follow` streams the
  log. `--param k=v` (repeatable; checked against declared type and choices; a
  missing required one is `param_required` unattended). `--for <instant>` (no
  offset = UTC; the run reads `TOFT_SCHEDULED_FOR`). **Two identical `toft job
  run`s are two runs** — the SDK's one-minute duplicate check is the app's
  route only; `--idempotency-key K` makes a repeat within 24h answer the first
  run (`deduplicated: true`, always present in the answer), and the same key
  with a different job, params or `--for` is exit 3 `idempotency_key_reused`.
  Params over 64 KB are `params_too_large` (put the data in a store; a param
  names it). `--no-wait` returns the run id; `--timeout <d>` bounds the wait
  (exit 1, code `wait_timeout`, retryable, naming `toft job wait <id>`; the run
  carries on).
- **`toft job rerun <runID>`** — new run, same params and `--for`,
  `rerun_of` set. **Nothing reruns automatically.** An unfinished run is exit 3
  `run_still_open` (wait or cancel first).
- **`toft job wait <runID>`** — wait for a run started elsewhere (schedule, app,
  browser, `--no-wait`); same output and exits as `run`.
- **`toft job runs [name]`** — recent runs with who started each (`app`,
  `viewer`, `cli`, `schedule`, `ui`); **`toft job runs <runID>`** — one run in
  full and the next command to type. Run ids may be the 8 characters it prints.
  A run document's **`logs_url` is the one your credential opens**: here
  `/api/v1/apps/<app-id>/job-runs/<id>/logs` (`toft job logs` reads it); the
  SDK's run, read with the app's own token, names
  `/api/v1/app/job-runs/<id>/logs` for the same log.
- **`toft job logs <runID>`** (`--follow`); **`toft job output <runID>`** — what
  it wrote with `write_output`, to stdout or `-o <file>` (`--force` to replace);
  `no_output` / `output_expired`.
- **`toft job cancel <runID>`** — on a finished run: `already finished
  (<status>)`, exit 0, `"changed":false`.

**A run ends in one of six words, on the last line**: `succeeded` (exit 0);
`failed`, `timed_out`, `out_of_memory`, `cancelled`, `skipped` (exit 1, with the
reason and the log tail). `skipped` is a scheduled run that never started —
`overlap = "skip"` and the previous run still going (the policy working: the
run's reason says so, and no event is recorded), or the app's queue full
(that one also records `job_schedule_skipped` in `toft events`, a warning the
job's next success resolves). Under `overlap = "queue"` a firing
waits behind the previous scheduled run; a run you start never does.

Refusals: `queue_full` exit 1 (retryable); `no_such_job`, `param_type`,
`param_choice`, `param_unknown`, `param_required` exit 2; `jobs_unavailable`
exit 3, kind `refused` (the install's hint says why — configuration, not your
job).
A static app runs no jobs, and a static deploy refuses `[jobs]`.

**Pausing** a job's schedule until the next deploy: the app's Automation tab, or
`PATCH /api/v1/apps/{id}/jobs/{name}` with `{"enabled": false}` — not
`toft.toml`.

### Scheduled restarts and re-renders

One of each per app, also only in `toft.toml`:

```toml
[restart]                    # a serving app: bounce it nightly
schedule = "0 4 * * *"
timezone = "Europe/London"   # optional; absent is UTC

[render]                     # a document: render it again as a new release
schedule = "0 6 * * 1"
```

Removing a table removes the schedule at the next deploy (a deploy warning and a
`schedule_removed` event; a re-render's recipients go with it). Pause until the
next deploy on the Settings tab, or `PATCH /api/v1/apps/{id}/restart-schedule`
(or `/render-schedule`) with `{"enabled": false}` — their `GET` answers
`schedule` in the stored form, `CRON_TZ=Europe/London 0 4 * * *` when a
`timezone` is declared, as a job's schedule is; a report's recipients are
`PUT /api/v1/apps/{id}/render-schedule/recipients`. Refusals (check and deploy):
`restart_no_service` (batch app), `restart_changes_nothing` (static or document
— a document wants `[render]`), `render_not_a_document`,
`schedule_too_frequent` (under an hour apart), `removed_key` (`enabled`). A
scheduled restart only restarts a *running* app; otherwise it is skipped and the
Settings tab says why.

## Storage declared in `toft.toml`

An app asks for storage an administrator has already created:

```toml
[[storage]]
name   = "sales-data"
access = "full"            # read, write or full; left out: what the storage can serve
folder = "2026"            # optional: one folder of the resource
path   = "/data/sales"     # optional: default /storage/<name>[/<folder>]
```

- **`toft storage ls`** — what you can attach and your ceiling on each;
  **`toft storage ls --app <slug>`** — what the app has, with `toft.toml` or
  `console` beside each. `--json` passes the install's answer through: one document,
  `{mappings, pending, note}` — not a list, so not one line per row.
- **The app's owner holds every entry**: the owner must be able to attach each
  at that level (a group-owned app through the group's *own* delegation).
  **The deployer is checked only on a change** — a new entry or a higher level.
  A deploy with no person (auto-deploy, a re-render) can keep and remove but not
  add; a deploy key adds only if an administrator gave it `may_attach`, and
  still on the owner's right.
- **`toft check` prints the plan** under `storage`: `+` added, `~` changed (with
  what it was), `-` detached (files kept), `=` kept — including `= name, kept:
  attached in the console` when the console attached it identically (never
  taken over). Refusals are `problems` with reason `storage_refused` and a code:
  `storage_unknown` (a name you hold nothing on — the same sentence whether or
  not it exists), `storage_not_attachable_by_owner`,
  `storage_not_attachable_by_you`, `storage_level_above_ceiling`,
  `storage_requires_person`, `storage_conflicts_console_mapping` (attached in the
  console differently — match it, or have it detached), …. An entry wrong on
  its own — no `name`, an `access` off read/write/full, a bad `path`, one
  resource twice, two entries at one path or one inside another (a resource
  whole and a folder of it at `/storage/x` and `/storage/x/f`) — is a
  `manifest_invalid` problem
  instead, with code `storage_entry_invalid`, `storage_name_ambiguous` or
  `storage_path_taken` and a `storage[i].<key>` field.
- **A `toft store` grant is not an attach right.** Holding a grant lets you move
  files with `toft store`; attaching the resource to an app needs a *manage
  delegation* from an administrator, to you or to the app's owner. A
  `[[storage]]` entry naming a resource you hold only a grant on is
  `storage_not_attachable_by_you`, and the message says what to ask for.
  **Nor is being an administrator**: an admin with no delegation gets the same
  code, with the two ways through — delegate to yourself or the owner, or attach
  it from the admin side (`toft api PUT admin/storage/<id>/mappings/<app-id>`)
  and leave it out of `toft.toml`.
- **Mounts change at the end of the deploy**, never during it; a store newly
  declared is not reachable by signed URL until the deploy finishes (an app
  minting one at boot fails its first deploy's readiness).
- **Removing an entry detaches it at the next deploy**; files stay. A declared
  mapping cannot be edited in the console (409 `declared_in_manifest`); a console
  detach is allowed, but the next deploy restores it.

## Files: `toft store`

`toft store ls|cp|mv|mkdir|rm|put|get` moves files in and out of storage you
hold a grant on — **an object store, or a volume on an install without a
cluster** (a folder on the Toft host; on a cluster, S3 Files volumes too). This
is how you load a dataset onto a volume before the app runs; no upload endpoint
in the app is needed. Only an EFS or Azure Files volume on a cluster is out of
reach: nothing but a pod mounting it can read it. On a bucket the transfer goes
**direct to the object store** (an unreachable bucket is exit 4 naming that
host); on host storage the install carries the bytes. Same commands either way.

Inside the app and its jobs, attached storage is in `TOFT_STORAGE` (JSON: name,
kind, access, folder, path; absent when none). Read the path from there or the
SDK's `mounts()`: on a cluster it is `/storage/<name>` by default, but without
a cluster it is a folder under the app's own directory —
`…/apps/<app-id>/storage/storage/<name>[/<folder>]`, the resource's folder inside
the app's `storage/` (the doubled `storage` is expected). Never build the path
yourself; read it.

**Every path prints as `toft://<store>/<path>`** (folders end in `/`), and every
subcommand takes that form back. `<store>/<path>` works too — for `cp`/`mv`
with `toft://` on neither side, only when nothing in the working directory has
the store's name (a local folder wins; write `toft://` to mean the store).

```
toft store ls                              # what you can reach, and at what level
toft store ls reports                      # one level: folders, then objects (-r: everything)
toft store get toft://reports/2026-08/q1.csv   # or: get reports 2026-08/q1.csv
toft store get reports/2026-08/q1.csv ./out/   # a second word is the destination
toft store get toft://reports/2026-08/q1.csv -o -   # to stdout
toft store put reports q1.csv                  # one file up
toft store cp -r ./out toft://reports/2026/march/
toft store cp -r toft://reports/2026/ ./reports
toft store mv toft://reports/draft.csv toft://reports/final.csv
toft store mkdir reports/2027
toft store rm -r --yes reports/2025/
```

- `ls --json` is `{"folders": [...], "objects": [...]}` (empty arrays, names
  relative to what was listed).
- **A partitioned store takes writes only inside folders apps are mapped to.**
  `toft store ls` shows them (or says none is mapped). A write elsewhere is exit
  3, `kind: refused`, `outside_mapped_folders`, with the install's hint naming
  the folders you can write in.
- **Exits**: 2 for a name that does not resolve (`not_found`) or is malformed
  (`bad_request`, `no_store` for `toft://` with no store), or a folder where an
  object was wanted (`is_a_folder` — `get`, and `cp`/`mv`/`rm` without `-r`,
  with or without the trailing slash); 3 for a refusal of level or folder; 1
  only when a transfer failed. `rm`, `cp` and `mv` resolve the source before
  anything moves: a missing source is exit 2 `not_found`, nothing transferred.
- **A batch in which every item was refused with one code is that refusal** —
  its exit and `code` (`cp` of one file onto an existing name at `write` is exit
  3 `already_exists`, as `put` is); a mixed batch is exit 1 "n of m failed", and
  `--json` items each carry their `code`.
- `get -o - --json` is exit 2 `conflicting_flags` (both want stdout).
- Each object moves on its own signed URL at your level on it. `-j N` parallel
  transfers (default 4); one failure does not stop the rest, exit 1 with a count.
- **`mv` is copy then delete**; a partial failure leaves two copies, never none.
  It needs `write` at the destination and `full` at the source — refused up front
  (exit 3 `insufficient_access`). At `write`, writing onto an existing name is
  exit 3 `already_exists`.
- **A download never overwrites a local file** without `--force`, and checks the
  whole tree first. Store-to-store copies pass through your machine (`TMPDIR`).
- A folder is a prefix; `mkdir` writes a marker (a second says `exists`). An
  upload writes markers only for empty local directories, and `cp -r` copies no
  marker of a folder that holds something. `rm -r` asks once with count and
  size (unattended it needs `--yes`) and empties a folder in one run, host
  storage included.

## The SDK locally: `toft sdk vendor`

A deployed app never needs this — the build installs the SDK. It is for an
editor, a local build or CI before the deploy:

```
toft sdk vendor                  # language detected from the tree
toft sdk vendor --lang python
```

It writes `.toft/sdk-<lang>/` from the install you are signed in to and prints a
build id the deploy log should match (a mismatch is a build-log warning, never a
failure). Re-run after the install upgrades. Per-language wiring (Go's
`go.work`, what is gitignored, what ships): see the **toft-sdk** skill.

## The escape hatch: `toft api`

`toft api <method> <path>` calls the install with the stored credential and
prints the install's JSON on stdout — **a refusal's too** (non-zero exit, no
second document).

```bash
toft api GET apps                                   # = GET /api/v1/apps
toft api GET apps/by-slug/<slug>                    # the app, with its id
toft api PATCH apps/$ID --data '{"name":"Sales report"}'
cat body.json | toft api POST apps/$ID/job-runs --data @-
```

- **Never read the credential out of the config file** — there is no supported
  way, and `toft api` exists so you never hold the key.
- A path without a leading slash is relative to `/api/v1/`. **Prefer it on
  Windows**: Git Bash/MSYS rewrites `/api/v1/…` into a Windows path before `toft`
  starts (or set `MSYS_NO_PATHCONV=1`).
- **`apps/` paths take the app's id, never its slug** (`toft status --json`
  gives `.app.id`).
- Exits, coarser than HTTP: **2** — no such route (`route_not_found`), wrong
  method (`method_not_allowed`, hint names the right one), 404, 400, 409
  `name_taken`, `param_*`, `no_such_job`, `params_too_large`; **3** — credential or permission, any
  other 409 (state refused), `jobs_unavailable`, `run_still_open`; **4** —
  unreachable; **1** — the rest: 5xx, 422, a 409 that is a wait
  (`deploy_queued`, `already_running`), `queue_full`. Branch on the body's
  `code`.
- **Finding a route**: `toft api GET admin/openapi.json` (an administrator's
  key) lists every path and method the install serves, with `x-toft-key-denied`
  on the ones a key cannot reach (use `--session` for those). It carries no
  request bodies; the console's own calls are the other reference.
- **Prefer a verb where one exists** — verbs validate arguments and survive route
  changes.

## What `toft` does not do

| | |
|---|---|
| An app's name, slug, branch, embedding origins or listing | `PATCH /api/v1/apps/{id}` with the field, or the Settings page. Env, visibility and hostname have verbs |
| Creating, editing or deleting a job, `[render]` or `[restart]` | Not a call: `toft.toml`, shipped with `toft deploy`. Pausing is above |
| How big the machine is | `toft api GET system/health` (an administrator): `system.memory_total` (bytes) and `system.cpu_count`, on an install without a cluster. A job limit set above them is saved with a `warning` |
| An app's tags | `PUT /api/v1/apps/{id}/tags` with ids of existing tags; creating tags is an administrator's |
| Grants, storage resources, delegations, storage mappings made in the console, integrations | Administrator surfaces (UI, or API with `--session`). An administrator's key can create storage and attach it; grants, managers and integrations need `--session`. **Create** is `POST admin/storage` with `{"name","kind"}` plus what the install asks for: `backing` (left out, the kind's default or the one the install offers, `host` where it offers host beside others; with several and neither, 422 `storage_backing_required` lists them — `GET admin/storage` does too; one named that the install does not offer is 422 `storage_backing_unavailable`), `storage_root` when the install keeps storage under host roots (left out, the single root when it declares one; with several, `storage_root_required` lists them), and `bucket` and `prefix` for a `store` or a bucket-backed volume. **Attach** is `PUT admin/storage/<id>/mappings/<app-id>` with `{"path","access","folder"}`, every key optional: `path` defaults to `/storage/<name>[/<folder>]` as in toft.toml; under a host root the level is the root's mount — `full` on a read-write root, `read` on a read-only one, anything else 400 `storage_level_unsupported` (leave `access` out to take it); `folder` is required on a partitioned resource (422 `storage_folder_required`). A path another of the app's mappings holds, or one inside or above it — the resource whole and a folder of it at `/storage/x` and `/storage/x/f` — is 409 `storage_path_taken` with a hint: an app holds a resource whole or by folder at nesting paths, not both. It takes effect at the app's next start — a restart or a deploy. `DELETE …/mappings/<app-id>` removes every mapping of that resource on the app; `?folder=<name>` removes one, and `?folder=` the whole-resource mapping. Attaching existing storage is a `[[storage]]` entry |
| Publishing from RStudio | rsconnect's own surface (`/__api__`, the install posing as Posit Connect); an agent deploys with `toft` |

## When something refuses

| What you see | What it is |
|---|---|
| `no app is linked in this directory` | `toft link <slug>`, or pass `--app` |
| `that key has expired` (exit 3, `key_expired`) | mint another and `toft login --token-stdin` |
| `invalid API key` (exit 3, `invalid_key`) | the install does not know this key — revoked, or minted on another install; check `TOFT_TOKEN`, or `toft login`. A credential not shaped like a key at all (not `toftu_…`/`toftd_…`) is the same refusal from `toft` itself, before anything is sent — a `TOFT_TOKEN` or a `--token-stdin` value alike |
| `key_read_scope` (exit 3) | a read-only key; ask for a full one. Retrying changes nothing |
| `unauthorized` (exit 3) | no credential reached a route that needs one — `toft login`, or set `TOFT_TOKEN` |
| `no_app_token` (exit 3) | a route only a deployed app calls, with its `TOFT_APP_TOKEN` — an SDK-built URL such as `logs_url` opened with a person's key; use `toft logs` / `toft job runs` instead |
| `app_key_removed` (exit 3) | a `toft_…` app key: that class was removed. Use a personal key (`toftu_…`) of an account granted on the app — `toft login` mints one |
| `forbidden` (exit 3, `deny_system_role`) | the account is a **viewer**; publishing needs the publisher role, which only an administrator grants. A **personal** key can ask: an empty `POST /api/v1/me/promotion-requests` (notifies administrators; 409 if one is pending) — then say who must act. A deploy key or service account cannot |
| `session_required` (exit 3) | an administrator's route; see `--session` |
| a license limit (exit 3) | a limit on the install; nothing deployed has stopped |
| deploy failed during `scan` | the dependency gate or the archive's caps; `reason` says which |
| a locked app (exit 2, kind `locked`) | an administrator or the dependency policy locked it. **Nothing was built**; retrying refuses until it is lifted |
| `no_such_job` (exit 2) | nothing ran. `toft job list` names what exists; a job not in a *deployed* `toft.toml` does not exist |
| `run_still_open` (exit 3) | `toft job wait <id>` or `toft job cancel <id>` first |
| `removed_key` / `limit_exceeds_ceiling` | a key Toft no longer reads, or a `timeout` above the ceiling; the hint is the line to write. For `memory`/`cpu`: delete it, and ask an administrator for an override |
| `jobs_unavailable` (exit 3) | this install cannot run jobs for this app; configuration, not a bug |
| `authentication required` from the app's URL | private app, no credential — use `toft fetch` or a bearer key |

## Full documentation

Markdown pages for the install's version live at `https://docs.gettoft.com/<minor>/`
(`latest/` is newest). Index with one-line summaries:
https://docs.gettoft.com/latest/llms.txt; `llms-cli.txt`, `llms-user.txt`,
`llms-admin.txt` beside it are whole guides in one file. Any page's address with
`.md` in place of its final `/` is that page as Markdown.

| What | Where |
|---|---|
| Installing `toft` | https://docs.gettoft.com/latest/cli/cli/installing.md |
| Signing in and API keys | https://docs.gettoft.com/latest/cli/cli/signing-in.md |
| Deploying | https://docs.gettoft.com/latest/cli/cli/deploying.md |
| Every command and flag | https://docs.gettoft.com/latest/cli/cli/commands.md |
| The app SDK | https://docs.gettoft.com/latest/cli/sdk/what-it-is.md |
| The user guide | https://docs.gettoft.com/latest/user/start/what-toft-is.md |
