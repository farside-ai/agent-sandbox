# Agent Sandbox for Zed

A Docker sandbox that runs **Claude Code** and **Codex** as external (ACP) agents
for the [Zed](https://zed.dev) editor. The agents — and every shell command they
run — execute inside an isolated container instead of directly on your machine.
You drive them entirely from Zed's agent panel.

## How it works

Zed talks to external agents over the **Agent Client Protocol (ACP)** — a JSON
stream over the agent process's stdin/stdout. Normally Zed spawns that process
locally. Here we point Zed at `docker exec` instead, so the agent process lives
inside a long-running container:

```
┌─────────── your Mac ───────────┐        ┌──── agent-sandbox container ────┐
│                                 │        │                                 │
│  Zed  ──spawns──▶ docker exec -i┼────────┼─▶ claude-agent-acp / codex-acp  │
│   ▲    (ACP over stdio)         │  pipe  │      │  (the agents run here)    │
│   │                             │        │      ▼                          │
│  you review diffs               │        │   edits files in /your/project  │
│                                 │        │   (mounted from the host)       │
└─────────────────────────────────┘        └─────────────────────────────────┘
```

- **Zed** (on your Mac) = the UI: chat, diff review, approvals.
- **The container** = where the agents and their commands actually run, confined
  to your project directory and the agents' own config.
- **`docker exec -i`** = the stdio pipe between them.

### The one important detail: matching paths

When Zed starts an agent session it sends the **absolute path** of the project
you opened as the agent's working directory. That path must exist *inside* the
container too, or the agent has nowhere to work. So the project is mounted at the
**same absolute path** in the container (not at `/workspace`). You set that path
once via `WORKSPACE_DIR`.

## Repository layout

```
agent-sandbox/
├── Dockerfile                  # the sandbox image (Node + git + the agents)
├── compose.yaml                # long-running container, mounts, auth, baseline hardening
├── compose.hardened.yaml       # opt-in egress network wall (overlay on compose.yaml)
├── compose.podman.yaml         # rootless-Podman overlay (keep-id) — see Portability
├── Makefile                    # build / up / down / shell / doctor / harden helpers
├── .env.example                # copy to .env: WORKSPACE_DIR + optional API keys
├── .dockerignore
├── .gitignore                  # ignores .env
├── .gitattributes              # forces LF on files read inside the container
├── egress-proxy/               # allowlisting forward proxy used by the wall
│   ├── Dockerfile
│   ├── tinyproxy.conf
│   └── filter                  # the egress allowlist (edit this)
├── zed/
│   ├── settings.snippet.jsonc         # agent_servers block (docker)
│   └── settings.snippet.podman.jsonc  # same, for podman
└── README.md
```

## Prerequisites

- Docker Desktop (or any Docker engine) running.
- Zed, recent enough to support custom ACP agents (`agent_servers`).
- Credentials for whichever agents you use: an Anthropic API key and/or an
  OpenAI/Codex key, or a Claude/ChatGPT subscription login.

## Setup

### 1. Configure

```sh
cp .env.example .env
```

Edit `.env`:

- **`WORKSPACE_DIR`** (required) — the absolute path of the project you'll open
  in Zed, e.g. `/Users/tom/code/my-app`. This is the only directory the agents
  can see.
- API keys (optional — see Authentication below).

### 2. Build & start

```sh
make build
make up
make doctor   # confirms both agents are installed and prints the workspace path
```

`make up` starts the container detached; it just idles (`sleep infinity`) waiting
for Zed to exec into it. Leave it running.

### 3. Authentication

Pick whichever you prefer per agent:

- **Option A — API keys (simplest).** Put them in `.env`
  (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY` / `CODEX_API_KEY`) and `make restart`.
  They're injected as environment variables the agents read automatically.
- **Option B — interactive login (use your subscription).** Log in *inside* the
  container:
  ```sh
  make claude   # then use /login
  make codex    # then follow the login prompt
  ```
  Credentials are written to the `claude-config` / `codex-config` named volumes,
  so they survive `make down` / `make up` and image rebuilds.

  > Note: on macOS the host Claude Code stores its login in the Keychain, which a
  > Linux container can't read — that's why we log in *inside* the container (or
  > use an API key) rather than mounting your host `~/.claude`.

### 4. Wire up Zed

Open Zed settings (`zed: open settings` from the command palette) and merge the
`agent_servers` block from [`zed/settings.snippet.jsonc`](zed/settings.snippet.jsonc)
into your `settings.json`. It adds two agents:

- **Claude (sandbox)** → `docker exec -i agent-sandbox claude-agent-acp`
- **Codex (sandbox)** → `docker exec -i agent-sandbox codex-acp`

## Daily use

1. Make sure the sandbox is up: `make up` (and the project equals `WORKSPACE_DIR`).
2. Open that project in Zed.
3. Open the **Agent panel**, click the **+** menu, and pick **Claude (sandbox)**
   or **Codex (sandbox)**.
4. Chat as usual. The agent runs in the container, edits files in your mounted
   project, and Zed shows the changes as diffs for you to review and accept.

To work on a different project, change `WORKSPACE_DIR` in `.env` and
`make restart`.

## Maintenance

| Command        | What it does                                              |
| -------------- | --------------------------------------------------------- |
| `make up`      | Start the sandbox                                         |
| `make down`    | Stop & remove the container (named volumes are kept)      |
| `make shell`   | Bash shell inside the sandbox                             |
| `make logs`    | Tail container logs                                       |
| `make doctor`  | Print versions of the agents + tools                      |
| `make rebuild` | Rebuild with `--no-cache` to pull newer agent versions    |

## Troubleshooting

- **Agent doesn't appear / fails to start in Zed** — the container must be
  running first (`make ps`). Check Zed's `dev: open acp logs` (command palette)
  to see the raw ACP handshake and any error.
- **Agent says it can't find files / wrong directory** — the project you opened
  in Zed must be exactly `WORKSPACE_DIR`. If you changed projects, update `.env`
  and `make restart`.
- **Auth errors** — confirm keys with `make shell` then `env | grep -i key`, or
  redo the in-container login (Option B). After editing `.env`, `make restart`.
- **Permission denied writing files** — on Linux hosts, files are created as
  uid 1000 (`node`). On macOS Docker Desktop handles ownership transparently.

## Hardening

The setup ships two tiers.

**Baseline (always on, in `compose.yaml`)** — zero UX cost:

- runs as non-root `node`, with `cap_drop: ALL` and `no-new-privileges`
- `/tmp` is a tmpfs (writable scratch that never hits the host)
- a single bind mount (`WORKSPACE_DIR`) — nothing else on your Mac is visible
- a `pids_limit` to curb fork bombs
- no secrets baked into the image; keys arrive only as runtime env vars

**Egress network wall (opt-in, `compose.hardened.yaml`)** — *default-deny outbound*:

```sh
make harden        # start with the wall (builds the proxy on first run)
make net-test      # proves it: api.anthropic.com connects, example.com is blocked
make harden-down   # stop the hardened stack
```

How it works: the sandbox is put on an `internal` Docker network with **no route
to the internet**. Its only way out is `egress-proxy`, a tiny forward proxy that
forwards exclusively to hosts in [`egress-proxy/filter`](egress-proxy/filter)
(default: the model APIs only — npm and everything else are blocked). Zed still
reaches the agents via `docker exec`, which goes through the Docker daemon rather
than the network, so the wall doesn't disturb the ACP connection.

Edit the allowlist in `egress-proxy/filter`, then `make harden-rebuild`.

### When to use the wall — and the trade-off

The wall blocks **outbound data exfiltration** and **`curl … | bash`-style
pull-and-run**, which is the main risk a prompt-injected or compromised agent
poses. The cost: the agent can only reach the allowlisted hosts, so anything that
fetches arbitrary URLs from the agent process is blocked:

- ✅ still works: model reasoning, and built-in **web _search_** (run server-side
  by the model provider, so it only needs the API host)
- ❌ blocked: **web _fetch_** of arbitrary pages, `git clone` / `curl` from
  non-allowlisted hosts, and `npm install` (npm is intentionally off the list)

So: run **default (wall off)** for normal trusted work where you want web access;
flip to **`make harden`** when pointing the agent at something you don't trust
(an unfamiliar repo, an auto-approve session).

## Portability (Podman, Windows)

The image and everything inside it is plain Linux, so it runs anywhere a Linux
container does. Two things are runtime/OS-specific.

### Podman

Supported. The Makefile is runtime-agnostic — just pass `RUNTIME=podman`:

```sh
make RUNTIME=podman build
make RUNTIME=podman up
make RUNTIME=podman harden     # hardened mode works too
```

When `RUNTIME=podman`, the Makefile automatically layers in
[`compose.podman.yaml`](compose.podman.yaml), which sets
`userns_mode: keep-id:uid=1000,gid=1000`. On **rootless Podman (Linux)** this maps
your host user onto the container's `node` user so files the agent writes into
your project stay owned by you, instead of a mapped subuid. (On macOS/Windows
Podman runs in a VM and this is harmless but usually unnecessary.)

For Zed, use [`zed/settings.snippet.podman.jsonc`](zed/settings.snippet.podman.jsonc)
— identical to the Docker snippet but it calls `podman exec` instead of
`docker exec`.

Requires `podman compose` (Podman 4/5) or `podman-compose`. Every compose feature
used here — `internal` networks, named volumes, `tmpfs`, `cap_drop`,
`no-new-privileges`, `init`, `depends_on` — is supported by Podman.

### Windows

Use **WSL2**, not native Windows paths. The design mounts your project at its
*identical absolute path* so it matches the working directory Zed sends the agent
(see "matching paths" above). A Windows path like `C:\Users\you\project` is **not
a valid path inside a Linux container**, so the mirror can't work natively.

The supported setup on Windows:

1. Run Docker Desktop (WSL2 backend) or a Podman machine.
2. Keep your project on the **WSL2 / Linux filesystem** (e.g. `/home/you/project`)
   and set `WORKSPACE_DIR` to that POSIX path.
3. Open that project in Zed at the same path so the cwd it sends matches.
4. Run the `make` commands from a WSL2 shell (`make` isn't on Windows by default;
   alternatively run the underlying `docker …` / `podman …` commands directly).

`.gitattributes` forces LF on the files read inside the container, so a Windows
checkout won't break the proxy config with CRLF line endings.

> Note: Zed's Windows support is comparatively new — confirm your build supports
> custom `agent_servers`.

## Security notes

- The agents can read and write **only** `WORKSPACE_DIR` and their own config
  volumes — nothing else on your Mac. Keep secrets (`.env` files, cred files) out
  of `WORKSPACE_DIR`, since the working tree — not just your source — is exposed.
- The biggest asset inside the sandbox is the **credentials** (API keys in env,
  OAuth tokens in the config volumes). Prefer a **dedicated API key with a spend
  cap** over your main subscription, so a leak is bounded and revocable.
- Secrets in `.env` are passed in as env vars; `.env` is gitignored — don't commit
  real keys.
- For untrusted work, combine the **egress wall** (above) with the agent's own
  per-command approval prompts (avoid blanket auto-approve).
