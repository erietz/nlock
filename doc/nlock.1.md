---
title: NLOCK
section: 1
header: User Commands
footer: nlock
date: October 7, 2026
---

# NAME

nlock, nlockd - run commands while holding named locks

# SYNOPSIS

**nlock run** [**-g**] [**-n**] [**-t** *seconds*] *name* **\-\-** *command* [*args*...]

**nlock list**

**nlockd**

# DESCRIPTION

**nlock** serializes commands across processes and terminals using named
locks. Each lock is identified by an arbitrary *name*. While one **nlock run**
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

    While the command runs, **nlock** ignores **SIGINT** and **SIGQUIT**;
    the terminal sends them to the command as well, and **nlock** releases
    the lock once the command exits. If **nlock** itself is killed, or loses
    its connection to **nlockd** for any reason, the daemon releases the lock
    on its behalf.

**list**
:   Print a table of the locks currently held. Each row shows the lock name,
    the user holding it, whether it was requested with **\-\-global**, and
    the command running under it. Takes no arguments.

    The user is taken from the kernel's credentials for the connecting
    socket, so it cannot be spoofed by the client. It is shown as a username,
    or as a numeric user ID if it has no entry in the user database.

# OPTIONS

**-g**, **\-\-global**
:   Request a global lock. This flag is accepted and sent to the daemon, but
    currently has no effect: all locks share a single namespace.

**-n**, **\-\-nonblock**
:   Do not wait. If the lock is already held, exit immediately with an error
    instead of queueing.

**-t**, **\-\-timeout** *seconds*
:   Wait at most *seconds* (a non-negative integer) for the lock. If the lock
    is not acquired in time, exit with an error without running the command.
    Without this option, **nlock** waits indefinitely.

# NLOCKD

**nlockd** runs in the foreground and takes no arguments. On startup it
removes any stale socket file at the socket path, then listens for
connections. It holds all lock state in memory; locks do not survive a
restart of the daemon. The socket file is removed when the daemon exits
cleanly.

# ENVIRONMENT

**NLOCK_SOCKET**
:   Path of the Unix domain socket used by both **nlock** and **nlockd**.
    Defaults to */tmp/nlock.sock*.

**NLOCK_LOG_LEVEL**
:   Logging verbosity for both programs, written to standard error. One of
    **Debug**, **Info**, **Warn**, **Error** or **None** (case-sensitive).
    Defaults to **None**.

# EXIT STATUS

**nlock** exits **0** once the lock has been acquired, the command has run
and the lock has been released. The exit status of *command* itself is not
propagated.

**nlock** exits **1** if the arguments are invalid, the daemon is not
running, the lock is busy with **\-\-nonblock**, the **\-\-timeout** expires,
or the lock could not be released.

# EXAMPLES

Run a build, waiting for any other build using the same lock:

    nlock run build -- make -j8

Give up if another deploy is already running:

    nlock run -n deploy -- ./deploy.sh

Wait at most 30 seconds for the lock:

    nlock run -t 30 db-migrate -- ./migrate.sh

Run a shell pipeline under a lock:

    nlock run logs -- sh -c 'cat *.log | gzip > logs.gz'

Start the daemon with a custom socket and debug logging:

    NLOCK_SOCKET=$HOME/.nlock.sock NLOCK_LOG_LEVEL=Debug nlockd

# BUGS

Report bugs to https://github.com/erietz/nlock/issues

# AUTHOR

Ethan Rietz ewrietz@gmail.com
