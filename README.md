# SSH Remote Commands

[![CI](https://github.com/caelicode/ssh-action/actions/workflows/ci.yml/badge.svg)](https://github.com/caelicode/ssh-action/actions/workflows/ci.yml)
[![Release](https://github.com/caelicode/ssh-action/actions/workflows/release.yml/badge.svg)](https://github.com/caelicode/ssh-action/actions/workflows/release.yml)

A GitHub Action to execute commands on remote servers via SSH. Uses native OpenSSH — no external binaries downloaded at runtime. Supports key and password authentication, environment variable forwarding, multi-host execution, jump/bastion hosts, configurable timeouts, and stdout capture.

## Features

- **Zero dependencies** — uses the runner's built-in OpenSSH, no binaries to download or cache
- **Key and password auth** — RSA, ED25519, ECDSA keys or password via `sshpass`
- **Multi-host execution** — comma-separated hosts with per-host error reporting
- **Jump/bastion host** — native `ProxyJump` support for reaching hosts behind firewalls
- **Environment forwarding** — securely pass GitHub secrets to the remote shell
- **Custom remote shell** — execute via `bash`, `sh`, `zsh`, or any shell on the target
- **Script file support** — run a local script file instead of inline commands
- **Stdout capture** — command output always available in `outputs.stdout`, even on failure
- **Configurable timeouts** — separate connection and command execution timeouts
- **Host key verification** — accept-new by default, or strict SHA256 fingerprint checking

## Usage

### Basic deployment

```yaml
- name: Deploy via SSH
  uses: caelicode/ssh-action@v1
  with:
    host: ${{ secrets.SERVER_HOST }}
    username: ${{ secrets.SERVER_USER }}
    key: ${{ secrets.SSH_PRIVATE_KEY }}
    script: |
      cd ~/my-app
      git pull origin main
      npm install --production
      pm2 restart my-app
```

### With environment variables

```yaml
- name: Deploy with secrets
  uses: caelicode/ssh-action@v1
  with:
    host: ${{ secrets.SERVER_HOST }}
    username: ${{ secrets.SERVER_USER }}
    key: ${{ secrets.SSH_PRIVATE_KEY }}
    envs: API_KEY,DATABASE_URL,NODE_ENV
    script: |
      cd ~/my-app
      echo "Deploying with NODE_ENV=$NODE_ENV"
      npm restart
  env:
    API_KEY: ${{ secrets.API_KEY }}
    DATABASE_URL: ${{ secrets.DATABASE_URL }}
    NODE_ENV: production
```

### Multiple hosts

```yaml
- name: Deploy to cluster
  uses: caelicode/ssh-action@v1
  with:
    host: 10.0.1.10, 10.0.1.11, 10.0.1.12
    username: deploy
    key: ${{ secrets.SSH_PRIVATE_KEY }}
    script: sudo systemctl restart my-service
```

### Via jump/bastion host

```yaml
- name: Deploy through bastion
  uses: caelicode/ssh-action@v1
  with:
    host: ${{ secrets.INTERNAL_HOST }}
    username: ${{ secrets.SERVER_USER }}
    key: ${{ secrets.SSH_PRIVATE_KEY }}
    proxy_host: ${{ secrets.BASTION_HOST }}
    proxy_username: ${{ secrets.BASTION_USER }}
    proxy_key: ${{ secrets.BASTION_KEY }}
    script: whoami
```

### Execute a local script file

```yaml
- name: Checkout
  uses: actions/checkout@v6

- name: Run deploy script
  uses: caelicode/ssh-action@v1
  with:
    host: ${{ secrets.SERVER_HOST }}
    username: ${{ secrets.SERVER_USER }}
    key: ${{ secrets.SSH_PRIVATE_KEY }}
    script_file: ./scripts/deploy.sh
```

### Capture output

```yaml
- name: Get server status
  id: status
  uses: caelicode/ssh-action@v1
  with:
    host: ${{ secrets.SERVER_HOST }}
    username: ${{ secrets.SERVER_USER }}
    key: ${{ secrets.SSH_PRIVATE_KEY }}
    script: uptime

- name: Use output
  run: echo "Server uptime — ${{ steps.status.outputs.stdout }}"
```

### Password authentication

```yaml
- name: Connect with password
  uses: caelicode/ssh-action@v1
  with:
    host: ${{ secrets.SERVER_HOST }}
    username: ${{ secrets.SERVER_USER }}
    password: ${{ secrets.SERVER_PASSWORD }}
    script: whoami
```

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `host` | SSH server hostname or IP (comma-separated for multi-host) | Yes | — |
| `port` | SSH port | No | `22` |
| `username` | SSH username | Yes | — |
| `key` | SSH private key content (RSA, ED25519, ECDSA) | No* | — |
| `password` | SSH password | No* | — |
| `envs` | Comma-separated env var names to forward | No | — |
| `script` | Commands to execute remotely | No** | — |
| `script_file` | Path to a local script file to execute | No** | — |
| `remote_shell` | Shell on the remote server | No | `bash` |
| `connect_timeout` | Connection timeout (seconds) | No | `30` |
| `command_timeout` | Script execution timeout (seconds, 0 = unlimited) | No | `600` |
| `fingerprint` | SHA256 host key fingerprint for strict verification | No | — |
| `proxy_host` | Jump/bastion host address | No | — |
| `proxy_port` | Jump host SSH port | No | `22` |
| `proxy_username` | Jump host username | No | — |
| `proxy_key` | Jump host SSH private key content | No | — |
| `request_pty` | Request pseudo-terminal | No | `false` |
| `args` | Additional SSH client arguments | No | — |

\* Either `key` or `password` must be provided.
\*\* Either `script` or `script_file` must be provided.

## Outputs

| Output | Description |
|--------|-------------|
| `stdout` | Standard output from the remote commands (captured even on failure) |

## How it works

1. Starts `ssh-agent` and loads the provided private key (or configures `sshpass` for password auth)
2. If a proxy key is provided, loads it into the agent and configures `ProxyJump`
3. Builds SSH options: `ServerAliveInterval=15`, `ConnectTimeout`, host key policy
4. If `envs` is set, constructs `export VAR='value'` statements prepended to the script
5. For each host (comma-separated), pipes the script to `ssh <host> <shell>` via stdin
6. Wraps execution with `timeout` if `command_timeout > 0`
7. Captures stdout to `$GITHUB_OUTPUT` (even on failure)
8. Cleans up SSH agent on exit via trap

## License

[MIT](LICENSE)
