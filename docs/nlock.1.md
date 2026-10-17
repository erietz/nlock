---
title: NLOCK
section: 1
header: User Commands
footer: nlock
date: October 16, 2026
---

# NAME

nlock, nlockd - run commands while holding named locks

# SYNOPSIS

**nlock run** [**-n**] [**-t** *seconds*] [**\-\-coalesce** | **\-\-replace**] *name* **\-\-** *command* [*args*...]

**nlock list** [**\-\-json** | **-q**] [**-H**]

**nlock** **-h** | **\-\-help**

**nlock \-\-version**

**nlockd**

# DESCRIPTION

**nlock** serializes commands across processes and terminals using named
locks. Each lock is identified by a *name* of up to 255 bytes, which may
contain any characters except whitespace and control characters, and may
not start with **-**. While one **nlock run**
holds a lock, any other **nlock run** for the same *name* waits until the lock
is released, then runs its own command. Waiters are served in the order they
arrived.

Locks are managed by the **nlockd** daemon, which must be running before
**nlock** is used. **nlock** connects to it over a Unix domain socket (see
**ENVIRONMENT**).

# COMMANDS

**run** *name* **\-\-** *command* [*args*...]
:   Acquire the lock *name*, run *command* with *args*, then release the lock.
    Everything after **\-\-** is the command; it is executed directly, not
    through a shell, and inherits **nlock**'s standard input, output and
    error. Options may appear before or after *name* but must precede
    **\-\-**. The lock is released when the command finishes, whether or not
    it succeeded.

    If the lock is held by someone else and standard error is a terminal,
    **nlock** prints who holds it before it starts waiting, for example:

        nlock: waiting for 'db' — held by alice (pid 4242) for 02:13: ./migrate --up (2 ahead of you)

    The elapsed time and queue position are as of when the request was
    queued. Nothing is printed when standard error is not a terminal, so
    scripts and cron jobs stay quiet.

    While the command runs, **nlock** ignores **SIGINT** and **SIGQUIT**;
    the terminal sends them to the command as well, and **nlock** releases
    the lock once the command exits. **SIGTERM** and **SIGHUP**, as sent by
    **kill**(1), **timeout**(1), a service manager or a closing terminal,
    are passed on to the command, and the lock is likewise held until it
    exits. If **nlock** itself is killed with **SIGKILL**, or loses its
    connection to **nlockd** for any reason, the daemon releases the lock on
    its behalf, even if the command is still running.

**list** [**\-\-json** | **-q**] [**-H**]
:   Print the locks currently held, one per line, sorted by name. By default
    the output is whitespace-aligned columns with a header row. When no
    locks are held, only the header row is printed, and **list** still exits
    **0**. The columns are:

    **NAME**
    :   The lock name.

    **PID**
    :   Process ID of the **nlock** client holding the lock (not of its
        command), or **-** if the platform cannot report it. It is taken from
        the kernel's credentials for the connecting socket, so it cannot be
        spoofed by the client.

    **ELAPSED**
    :   How long the current holder has held the lock, as
        [[*dd*-]*hh*:]*mm*:*ss*, like **ps -o etime**.

    **WAITERS**
    :   Number of clients queued for the lock.

    **CMD**
    :   The command running under the lock. It is always the last column,
        since it is the only one that may contain spaces; every other column
        can be split on whitespace. Control characters are shown escaped
        (**\\n**, **\\t**, **\\r**, **\\x***NN*) so each lock stays on one
        line. Commands longer than 4096 bytes are truncated and end in
        **...**; this affects only what is shown, not what runs.

# OPTIONS

**-h**, **\-\-help**
:   Print a summary of the commands and options to standard output and
    exit.

**\-\-version**
:   Print the version and exit.

Either option is honored anywhere among **nlock**'s own arguments, but not
after **\-\-**, where it belongs to *command*.

## run

**-n**, **\-\-nonblock**
:   Do not wait. If the lock is already held, exit immediately with an error
    instead of queueing.

**-t**, **\-\-timeout** *seconds*
:   Wait at most *seconds* (a non-negative integer) for the lock. If the lock
    is not acquired in time, exit with an error without running the command.
    Without this option, **nlock** waits indefinitely.

**\-\-coalesce**
:   If other clients are already waiting for the lock, exit **0** at once
    without running the command. A queued client has not started yet, so
    its run happens after this request was made and sees whatever prompted
    it. Many triggers in a row, such as file saves or git hooks, collapse
    into one run in progress and one pending. If nobody is waiting, queue as
    usual. This takes precedence over **\-\-nonblock**. Cannot be combined
    with **\-\-replace**.

**\-\-replace**
:   Take the place of every client waiting for the lock. They stop waiting
    and exit **0** without running their commands, and this request is
    queued instead, so the newest request is the next to run. Useful when
    only the latest request matters, such as deploying the newest commit.
    With **\-\-nonblock**, a held lock still fails without replacing
    anyone. Cannot be combined with **\-\-coalesce**.

    Both options treat every request for the same *name* as the same job,
    whatever its command. Put anything that distinguishes jobs, such as a
    deploy target, in the name. When standard error is a terminal, a client
    that does not run its command because of either option says why.

## list

**\-\-json**
:   Print one JSON object per lock, one per line, with the fields **name**,
    **pid**, **waiters**, **acquired_at** (seconds since the Unix epoch)
    and **command**. Names and commands are
    reproduced exactly, so prefer this format in scripts. Cannot be combined
    with **-q**.

**-q**, **\-\-quiet**
:   Print only lock names, one per line.

**-H**, **\-\-no-header**
:   Omit the header row from the default output.

# NLOCKD

**nlockd** runs in the foreground and takes no arguments, so it is meant to
be started by a service manager (see **RUNNING NLOCKD AS A SERVICE**) or
directly in a terminal. Where its messages go depends on which (see
**LOGGING**). Each user runs their own
**nlockd**, and **nlock** only talks to a daemon owned by the same user or by
root.

Only one **nlockd** can serve a given socket path. On startup it takes an
exclusive lock on *socket*.lock; if another daemon holds it, **nlockd** exits
with status 1. Having taken the lock, it removes any stale socket file left
by a daemon that did not exit cleanly, then listens for connections. The
socket and lock file are created readable and writable by the owner only.

All lock state is held in memory; locks do not survive a restart of the
daemon. On **SIGTERM**, **SIGINT** or **SIGHUP** the daemon removes its
socket and exits with status 0; clients still connected lose their locks.

# RUNNING NLOCKD AS A SERVICE

**zig build install** installs a service definition alongside the binaries,
pointing at the installed **nlockd**.

On Linux, a systemd user unit is installed as
*PREFIX*/share/systemd/user/nlockd.service. Start it now and at every login
with:

    systemctl --user daemon-reload
    systemctl --user enable --now nlockd

On macOS, a launchd agent is installed as
*PREFIX*/share/nlock/launchd/com.erietz.nlockd.plist. Copy it to
*~/Library/LaunchAgents* and load it with:

    launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.erietz.nlockd.plist

and unload it with:

    launchctl bootout gui/$(id -u)/com.erietz.nlockd

When installed with Homebrew, use **brew services start nlock** instead.

Both service definitions set **NLOCK_LOG_LEVEL**=**Debug**.

# LOGGING

When its standard error is a terminal, **nlockd** logs there, as **nlock**
does. Otherwise, as when it runs under systemd or launchd, it logs to
**syslog**(3) with the identifier **nlockd**, mapping each message's level to
the matching syslog priority. View the messages with:

    journalctl --user -u nlockd -f                              # Linux
    log stream --style compact --process nlockd --level debug   # macOS

Syslog is used because launchd discards a job's standard error unless its
plist names a file, which is then never rotated. Syslog messages reach the
macOS unified log and, on Linux, the systemd journal, both of which rotate
their storage and keep each message's level, so **journalctl -p** can filter
by it. On macOS, debug messages are only kept while something such as **log
stream \-\-level debug** is collecting them, so **log show** will not find
them afterwards.

Fatal startup errors are always printed to standard error, and are also sent
to syslog when **nlockd** is logging there.

# ENVIRONMENT

**NLOCK_SOCKET**
:   Path of the Unix domain socket used by both **nlock** and **nlockd**.
    **nlock** and **nlockd** must agree on the path, so if you set it for
    one, set it for both, including in the service definition. When unset or
    empty, the default is the first of:

    - *$XDG_RUNTIME_DIR*/nlock.sock on Linux, if **XDG_RUNTIME_DIR** is set
    - nlock.sock in the per-user temporary directory on macOS (see
      **getconf DARWIN_USER_TEMP_DIR**)
    - /tmp/nlock-*uid*.sock

**NLOCK_LOG_LEVEL**
:   Logging verbosity for both programs (see **LOGGING** for where
    **nlockd** writes it). One of
    **Debug**, **Info**, **Warn**, **Error** or **None** (case-sensitive).
    Defaults to **None**. Fatal **nlockd** startup errors are always
    printed.

# FILES

*socket*.lock
:   Held by the running **nlockd** to prevent a second daemon on the same
    socket. It is left in place when the daemon exits; this is intentional.

# EXIT STATUS

**nlock run** exits with the exit status of *command*, so it can be used in
place of the command in scripts and **&&** chains. With **\-\-coalesce** or
**\-\-replace**, it exits **0** without running *command* when another
request will run instead; **0** then means a run is scheduled, not that it
succeeded. If a signal ends
*command*, **nlock** exits with 128 plus the signal number, as a shell
reports it. If *command* cannot be run, **nlock** exits **127** when it is
not found and **126** otherwise.

When **nlock** itself fails, it exits with one of the following codes from
**sysexits**(3). A *command* that exits with one of these values cannot be
told apart from **nlock** failing.

**64** (EX_USAGE)
:   The arguments are invalid. A short usage message is printed to standard
    error.

**69** (EX_UNAVAILABLE)
:   **nlockd** is not running, cannot be reached, or its socket belongs to
    another user.

**70** (EX_SOFTWARE)
:   The lock could not be released, the daemon's identity could not be
    verified, or another unexpected error occurred.

**71** (EX_OSERR)
:   An operating system error occurred, such as failing to read the
    arguments or to write output.

**72** (EX_OSFILE)
:   The socket path is not a valid Unix domain socket address, for example
    because it is too long.

**75** (EX_TEMPFAIL)
:   The lock is busy and **\-\-nonblock** was given, or the **\-\-timeout**
    expired before the lock was acquired. Retrying later may succeed.

**nlock list**, **nlock \-\-help** and **nlock \-\-version** exit **0** on success.

# EXAMPLES

Run a build, waiting for any other build using the same lock:

    nlock run build -- make -j8

Give up if another deploy is already running:

    nlock run -n deploy -- ./deploy.sh

Wait at most 30 seconds for the lock:

    nlock run -t 30 db-migrate -- ./migrate.sh

Rebuild on every save, but never queue more than one extra build:

    fswatch -o src/ | while read -r _; do
        nlock run --coalesce build -- make &
    done

Deploy only the newest pushed revision, dropping any that are still waiting:

    nlock run --replace deploy -- ./deploy.sh "$newrev"

Run a shell pipeline under a lock:

    nlock run logs -- sh -c 'cat *.log | gzip > logs.gz'

Show the locks that have clients queued for them:

    nlock list -H | awk '$4 > 0 { print $1 }'

Check whether a lock is currently held:

    nlock list -q | grep -qx build && echo "build is locked"

Print the command running under each lock:

    nlock list --json | jq -r '"\(.name): \(.command)"'

Start the daemon with a custom socket and debug logging:

    NLOCK_SOCKET=$HOME/.nlock.sock NLOCK_LOG_LEVEL=Debug nlockd

# BUGS

Report bugs to https://github.com/erietz/nlock/issues

# AUTHOR

Ethan Rietz ewrietz@gmail.com
