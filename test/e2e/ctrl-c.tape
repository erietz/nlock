# Ctrl+C on a waiting client drops it from the queue. Ctrl+C on a holder
# reaches its command, and nlock exits with the command's status (128 + 2)
# and releases the lock.

Source test/e2e/setup.tape

# Top: hold the lock
Type "nlock run db -- sleep 60" Enter
Sleep 0.5

# Middle: wait for it, then give up
Ctrl+B
Down
Type "nlock run db -- echo waiter-ran" Enter
Wait+Screen@5s /nlock: waiting for 'db'/
Ctrl+C
Type "echo waiter-status=$?" Enter
Wait+Screen@5s /(?m)^waiter-status=130/

# Bottom: the holder is still listed, with no waiters
Ctrl+B
Down
Type "nlock list" Enter
Wait+Screen@5s /db\s+\d+\s+\d\d:\d\d\s+0\s+exclusive\s+-\s+sleep 60/

# Top: interrupt the holder's command
Ctrl+B
Up
Ctrl+B
Up
Ctrl+C
Type "echo holder-status=$?" Enter
Wait+Screen@5s /(?m)^holder-status=130/

# Bottom: the lock is free
Ctrl+B
Down
Ctrl+B
Down
Type "nlock run -n db -- echo db-is-free" Enter
Wait+Screen@5s /(?m)^db-is-free/
