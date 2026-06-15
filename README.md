# gh-accounts

> GitHub multi-account SSH manager (TUI)

## Overview

`gh-accounts` is a terminal UI (TUI) for managing multiple GitHub SSH identities. It stores accounts in `~/.ssh/.gh_accounts`, generates keys, manages `~/.ssh/config`, and updates your Git global config for the selected primary account.

## Requirements

- **Bash** 4+
- **ssh-agent** / **ssh-add** / **ssh-keygen**
- **git**
- **curl** (for GitHub API verification, optional)
- Terminal with `tput` support

> python3 is **no longer required** — config management is pure bash.

## Installation

```bash
bash install.sh                     # symlink to ./bin/gh-accounts
bash install.sh --dest ~/.local/bin # or custom location
```

Make sure the destination is in your `PATH`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Usage

```bash
gh-accounts
```

### Keybindings

| Key | Action |
|-----|--------|
| `a` | Add new account (username, email, host alias, key file, notes) |
| `d` / `Del` | Delete selected account |
| `s` | Set selected account as primary (updates global git config + SSH config) |
| `t` | Test SSH auth for selected account |
| `T` | Test SSH auth for **all** accounts |
| `r` | Show repo config helper (git commands for a local repo) |
| `i` | Import existing SSH key from `~/.ssh/` |
| `R` | Rotate SSH key (generates new keypair, backs up old) |
| `V` | Verify username via GitHub API |
| `/` | Filter accounts (type to search, Enter to confirm, Esc to clear) |
| `S` | Cycle sort order: none → name → status → role → none |
| `?` | Show help screen |
| `j` / `↓` | Move down |
| `k` / `↑` | Move up |
| `PgDn` / `Ctrl-D` | Page down |
| `PgUp` / `Ctrl-U` | Page up |
| `q` | Quit |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `GH_ACCOUNTS_FLASH` | `0.8` | Duration (seconds) for flash messages |

## Features

- **Multi-account management** — Add, delete, and switch between multiple GitHub SSH identities
- **Primary account** — One account gets the `github.com` host; others use custom host aliases
- **SSH key generation** — Choose ed25519, RSA (4096-bit), or ECDSA (521-bit)
- **Key rotation** — Regenerate keys for existing accounts (old keys backed up as `.old`)
- **Import keys** — Detect and import existing SSH keys not yet tracked
- **Batch testing** — Test SSH auth for all accounts at once
- **GitHub verification** — Verify usernames via GitHub API
- **SSH config management** — Auto-manages `~/.ssh/config` with marked blocks, backed up before each change
- **Auto ssh-agent** — Starts `ssh-agent` automatically if not running
- **Account sorting** — Sort by name, status, or role
- **Account notes** — Optional notes field for each account
- **Key file indicator** — Detail panel shows green/red for key file existence
- **Responsive layout** — Adapts columns based on terminal width
- **Store migration** — Automatically migrates older 5-field store to 6-field format

## Files

| File | Purpose |
|------|---------|
| `~/.ssh/.gh_accounts` | Account store (pipe-delimited, one line per account) |
| `~/.ssh/config` | SSH config (managed blocks marked with `# gh-accounts:`) |
| `~/.ssh/config.bak` | Backup of SSH config before each rewrite |

### Store Format

```
username|email|host-alias|keyfile|status|notes
```

## Signal Handling

Ctrl-C (SIGINT) and SIGTERM run the cleanup routine and restore the terminal. SIGWINCH triggers a full redraw on terminal resize.

## Troubleshooting

- **Terminal stuck after exit**: Run `tput rmcup; tput cnorm; reset`
- **"requires an interactive terminal"**: Run from a tty, not a backgrounded job
- **SSH auth failures**: Verify key files exist, ssh-agent is running, keys are added
- **Permission denied on install**: Use `--dest ~/.local/bin` or run with `sudo` for `/usr/local/bin`

## License

MIT
