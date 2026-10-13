nlock, nlockd - run commands while holding named locks

See [the man page](./docs/nlock.1.md) for the full documentation.

# Installation

## Homebrew

```
# install the tap and the formula
brew tap erietz/tap
brew install nlock

# start the daemon automatically on login
brew services start nlock
```

## From source (user installation)

To install from source:

1. Clone the repository:
    ```bash
    git clone https://github.com/erietz/nlock.git
    cd nlock

    # Trust the mise.toml file
    mise trust
    # Install the dependencies
    mise install
    # Build and install to ~/.local as the prefined prefix
    mise run install
    ```
2. Start the nlockd service:
    1. Linux:
        ```bash
        mise run daemon-systemd-user-start
        ```
    2. macOS:
        ```bash
        mise run daemon-launchd-user-start
        ```

If you do not have `mise` installed, view the commands in `./mise.toml` and run
them manually.
# Examples

Every `nlock run` that uses the same lock name waits its turn and runs in
arrival order. The lock is released when the command exits, including when it
crashes or is killed. Locks are per user and cover everything you run: other
terminals, tmux panes, cron jobs, editors and agents.

**Skip a cron run if the previous one is still going:**

```cron
# Linux: cron does not set XDG_RUNTIME_DIR, so point nlock at the daemon's socket
NLOCK_SOCKET=/run/user/1000/nlock.sock
*/15 * * * * nlock run -n backup -- restic backup ~/Documents
```

**Take turns on a shared resource.** Start this from as many terminals as you
like and the jobs queue up instead of competing for the GPU:

```bash
nlock run gpu -- python train.py --config large.yaml
```

**Fan out the work and serialize the writes.** Eight downloads run at once,
and each response is appended whole, never interleaved with another:

```bash
seq 100 | xargs -P 8 -I{} sh -c \
  'curl -s https://jsonplaceholder.typicode.com/posts/{} | nlock run results -- tee -a results.jsonl > /dev/null'
```

**Let parallel coding agents share one test database.** Put the command in
`AGENTS.md` or `CLAUDE.md`, and agents in separate worktrees queue for the
database instead of breaking each other's test runs:

```bash
nlock run test-db -- npm test
```

**Chain on the result.** `nlock run` exits with the command's exit status, so
it works with `&&`, `||` and `set -e` like the command alone would:

```bash
nlock run build -- make -j8 && ./bin/app
nlock run deploy -- ./deploy.sh || notify-send "deploy failed"
```

**Block a push when the tests fail.** Worktrees share one hooks directory, so
pushes from parallel worktrees take turns running the suite. Save this as
`.git/hooks/pre-push` and make it executable:

```sh
#!/bin/sh
exec nlock run test-db -- npm test
```

**Use a path as the lock name.** A lock name can be any string, so naming a
lock after the thing it protects keeps unrelated jobs from blocking each other:

```bash
# Builds in the same checkout take turns; separate worktrees build in parallel
nlock run "$PWD" -- make -j8

# Two uploads to the same board can't collide on the serial port
nlock run /dev/ttyACM0 -- arduino-cli upload -p /dev/ttyACM0 --fqbn arduino:avr:uno Blink

# Backups to the same disk run one after another instead of competing for it
nlock run /Volumes/Backup -- rsync -a ~/Pictures/ /Volumes/Backup/Pictures/

# A migration and a bulk import never write to the database at the same time
nlock run ~/app/dev.db -- ./migrate.sh
nlock run ~/app/dev.db -- ./import.sh data.csv
```

**Hold a lock by hand.** Open a shell under the lock, and anything else that
takes `deploy` waits until you exit:

```bash
nlock run deploy -- "$SHELL"
```

**Choose how long to wait:**

```bash
nlock run -n deploy -- ./deploy.sh       # exit 1 right away if a deploy is running
nlock run -t 300 deploy -- ./deploy.sh   # give up after 5 minutes
```

**See which locks are held, by whom, and who is waiting:**

```bash
watch -n 1 nlock list
```

```text
NAME     USER    PID  SCOPE  ELAPSED  WAITERS  CMD
gpu      ethan  4121  user     12:41        2  python train.py --config large.yaml
test-db  ethan  4377  user     00:08        1  npm test
```

**Find locks held for more than an hour:**

```bash
nlock list --json | jq -r --argjson now "$(date +%s)" \
  'select($now - .acquired_at > 3600) | "\(.name): pid \(.pid), \(.command)"'
```

See `man nlock` for every option.
