# toft — the Toft command-line client

`toft` deploys a directory on your disk to a [Toft](https://github.com/larchway-labs/toft-install)
install, watches the build, and reads the logs afterwards.

```bash
curl -fsSL https://raw.githubusercontent.com/larchway-labs/toft-cli/main/install.sh | sh
```

One binary. No dependencies, no daemon, no root — it lands in `/usr/local/bin`
if you can write there and `~/.local/bin` if you cannot, and the script tells
you which.

**Linux, macOS and Windows.** The install script covers Linux and macOS; on
Windows it names the file to download rather than failing at one.

The binaries are unsigned. On macOS that is invisible when you install with the
script — `curl` does not mark a download the way a browser does. On Windows,
Smart App Control may refuse `toft.exe` outright; if it does, there is no
per-file exception to add and turning Smart App Control off is not a trade
worth making for a CLI.

**This repository holds the binaries, not the source.** Each release carries one
build per platform plus a `SHA256SUMS` the installer checks.

## Getting started

```bash
toft login https://toft.your-company.com   # opens a browser, once
cd ~/code/my-app
toft link my-app                                # names the app this directory deploys to
toft deploy                                     # pushes what is on your disk
```

`toft deploy` bundles the working tree — respecting every `.gitignore` in it — and
uploads it. It does not need a git remote, a commit, or even a repository; a
plain folder deploys.

## The commands

| | |
|---|---|
| `toft login [url]` | Sign in to an install. `--status` says who and where, `--forget` drops a stored credential (`--forget-all` every one), `--token-stdin` for CI |
| `toft link <app>` | Record which app this directory deploys to. `--local` keeps it out of git |
| `toft deploy [dir]` | Bundle and upload. `--logs` interleaves the build log, `--json` for scripts |
| `toft status` | What is serving, since when, and from what |
| `toft deps` | What the dependency policy says about the app. If a deploy was refused, this is the packages, the advisories and the versions that fix it |
| `toft logs` | The app's log. `--follow`, or `--deploy <id>` for one build's output |
| `toft rollback [id]` | Back to the previous deployment. Names it before it acts |
| `toft create [dir]` | Make a new app and deploy this directory into it. Tells you the name it will take and asks first. `--repo <url>` to build from a repository instead, and `--subdir <folder>` with it to build one folder of a repository that holds several apps |
| `toft redeploy` | Build again from the app's own repository. Sends nothing from your disk |
| `toft restart` / `toft start` | Restart the app, starting it if it is stopped. `--wait` waits until it is up and fails if it never comes up |
| `toft stop` | Stop the app |
| `toft events` | What has gone wrong with this app. `--since 2h`, `--severity`, `--kind` |
| `toft job list\|run\|runs\|logs\|cancel` | Jobs, which run in a container where the install has a cluster and on the install's own machine where it does not, each with its own memory limit. `toft job run` waits for the job and fails if it fails. `--param k=v` to pass values, `--for <time>` to name the instant the run is for |
| `toft task list\|create\|edit\|delete\|run\|runs\|logs` | Scheduled tasks, which are HTTP requests to a path your app publishes. `create` needs `--path`, and `--schedule` (with `--timezone` for a zone other than UTC) only if you want the platform to call it on a timetable; `edit` changes only the fields you name |
| `toft apps` | The apps you can see. `--mine` |
| `toft store ls\|cp\|mv\|mkdir\|rm\|put\|get` | Files in an app's durable store. `cp -r` copies whole folders up and down (`toft://<store>/<path>` is the store side), `mv` renames, `mkdir` makes an empty folder, `rm -r` deletes one |
| `toft sdk vendor` | The app SDK this install carries, written into your working directory so your editor, `go build` and your CI can see it |
| `toft api <method> <path>` | Call this install's HTTP API with the credential `toft` already holds — the way round a verb `toft` does not have, without putting the key in a shell variable. `--data` takes JSON, `@file` or `@-`. A path with no leading slash is read as relative to `/api/v1/`, so `toft api GET apps` and `toft api GET /api/v1/apps` are the same call |

Every command takes `--help`, and every command takes `--json`.

## Reading the output from a script

`--json` puts the answer on standard output and leaves the running commentary on
standard error, so `toft status --json | jq -r .url` works without thinking about
it. Two things are worth knowing:

- **A failed deploy tells you what to do about it.** The result object carries
  `reason` — a short key like `build_failed`, `start_failed` or
  `dependency_blocked` — the whole failure message, and the detail that goes with
  it: the tail of the build log, or, when the dependency policy refused it, the
  packages and the versions that fix them.
- **A refusal is JSON too.** An expired key, a missing app, an install that did
  not answer: under `--json` each writes one object with the message, the exit
  code and what kind of problem it was. You still get the sentence on standard
  error.

## Platforms

| | |
|---|---|
| Linux | x86_64 and arm64 — the install script above |
| macOS | Intel and Apple Silicon — the same install script |
| Windows | x86_64 — download `toft_windows_amd64.exe` from [Releases](https://github.com/larchway-labs/toft-cli/releases), rename it `toft.exe`, and put it somewhere on your PATH |

### Windows

```powershell
curl.exe -fsSLo toft.exe https://github.com/larchway-labs/toft-cli/releases/latest/download/toft_windows_amd64.exe
```

Windows may warn about a program from an unknown publisher the first time you
run it — the binaries are not code-signed yet.

**If you run `toft` from Git Bash**, set `MSYS_NO_PATHCONV=1` first, or use paths
without a leading slash. Git Bash rewrites an argument that looks like a Unix
path into a Windows one before `toft` starts, so `toft api GET /api/v1/apps` arrives
as `C:/Program Files/Git/api/v1/apps`. `toft` recognises that and says so, but the
relative form — `toft api GET apps` — is never rewritten and needs nothing.

## Configuration

Everything resolves the same way, most specific first:

> `--flag` → `TOFT_*` → `.toft.toml` → `toft.toml` → `~/.config/toft/config.toml` → the default

`TOFT_URL` and `TOFT_APP` are the two environment variables.

**The credential is never a flag.** `toft login` writes it to
`~/.config/toft/credentials.toml` at mode `0600`; CI reads it from
`TOFT_TOKEN` instead. That file holds credentials and nothing else — the
settings live beside it in `config.toml`, so a file you are meant to edit and a
file with a secret in it never become one file.

## In CI

Have an administrator create a deploy key (`toftd_`, **Admin → Deploy keys**) —
or use a personal key (`toftu_`, **Your account → Credentials**) — put it in the
runner's secret store, and:

```bash
export TOFT_URL=https://toft.your-company.com
export TOFT_TOKEN=toftd_...
toft deploy --no-watch
```

**Give that key full access, not read-only.** A key's scope is chosen when it is
minted and cannot be widened afterwards — a read-only one is replaced, not
changed. It will fetch status and logs quite happily and then fail every deploy
with exit 3, which in a pipeline log looks like a permissions problem with the
account rather than a choice somebody made on the keys page. Signing in with
`toft login` always creates a full key, so this only bites a key pasted in from
the browser.

Where the runner mounts secrets as files rather than exporting them, use
`TOFT_TOKEN_FILE` and give it the path — an environment variable is visible
in `/proc`, inherited by every child process and printed by any diagnostic that
dumps the environment, while a path is not sensitive. Setting both is refused
rather than resolved: a job exporting two tokens does not know which one it is
using.

`toft` detects that nothing can answer a prompt — stdin is not a terminal, or `CI`
is set — and exits rather than hanging on a confirmation nobody can see.

A whole pipeline is the same shape. Each step fails the build if it fails, so
you do not need to check anything yourself:

```bash
toft deploy                 # ship it, and wait for the build
toft job run migrate        # run the migration, and wait for it
toft restart --wait         # pick up the new configuration, and wait for it
```

If a step fails, `toft events` says what the platform noticed.

**Exit codes are a contract:**

| | |
|---|---|
| `0` | It worked |
| `1` | The platform did the thing and it failed — a failed build, a refused bundle |
| `2` | Usage or configuration: no app linked, a bad flag, a name that does not exist, a path no route on the install matches, a prompt that could not be asked, or an app an administrator has locked |
| `3` | Not authenticated, or refused. If it says your account is a viewer, creating and deploying apps needs the publisher role — ask an administrator for it |
| `4` | Could not reach the install |

## For coding agents

This repository also carries two skills — the instructions a coding agent needs
to ship an app here without a person watching:

| | |
|---|---|
| [`skills/toft-cli`](skills/toft-cli/SKILL.md) | signing in without a browser, the deploy loop, the exit codes, what goes in the bundle, and what `toft` deliberately does not do |
| [`skills/toft-sdk`](skills/toft-sdk/SKILL.md) | writing the app itself: `PORT`, `HOST` and `BASE_PATH`, how the build detects a framework, `toft.toml`, and the app SDK |

For Claude Code, drop them where it looks for skills:

```bash
for s in toft-cli toft-sdk; do
    mkdir -p ~/.claude/skills/$s
    curl -fsSL -o ~/.claude/skills/$s/SKILL.md \
        https://raw.githubusercontent.com/larchway-labs/toft-cli/main/skills/$s/SKILL.md
done
```

**No local runtime is required to deploy.** The install builds: it resolves and
installs dependencies, picks the language version, and starts the app. An agent
with this binary and a key can create an app, push a directory, read the build
log and roll back without Node, Python or a Go toolchain on the machine it is
working on.

## Documentation

The full guide — every command and flag, signing in, deploying, CI and the app
SDK — is at **https://larchway-labs.github.io/toft-docs/latest/cli/**. Toft's user and admin guides are on the same site.

## Verifying a download

```bash
curl -fsSLO https://github.com/larchway-labs/toft-cli/releases/download/v0.1.0/toft_linux_amd64
curl -fsSLO https://github.com/larchway-labs/toft-cli/releases/download/v0.1.0/SHA256SUMS
grep toft_linux_amd64 SHA256SUMS | sha256sum -c
```

The installer does this for you.

## Versions

`toft` and the install it talks to share one version number, and an older client
against a newer install is the normal case rather than a problem: `toft` says so
in one dimmed line, renders anything it does not recognise by name, and carries
on. It is never refused for being old.

## Upgrading

Re-run the installer. It downloads the newest published release, checks it
against `SHA256SUMS`, and renames the new binary over the old one — so it is
also how you upgrade a `toft` that is running.

```bash
curl -fsSL https://raw.githubusercontent.com/larchway-labs/toft-cli/main/install.sh | sh
```

`toft --version` says which one you have. To install a particular release, or to
go back to one, pass the version through to the script:

```bash
curl -fsSL https://raw.githubusercontent.com/larchway-labs/toft-cli/main/install.sh | sh -s -- --version 0.1.0
```

`--version latest` follows the newest release rather than the one the script was
published with; `--dir` puts it somewhere else. Nothing else is kept anywhere —
`~/.config/toft` is untouched by an upgrade, so you stay signed in.

On **Windows**, download `toft_windows_amd64.exe` again and replace your `toft.exe`
with it. Nothing else changes.

## Uninstalling

```bash
rm "$(command -v toft)"
rm -rf ~/.config/toft
```

Deleting the credential file does **not** revoke the keys — that is the keys
page in your install.
