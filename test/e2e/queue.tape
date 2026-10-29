# A second `nlock run` from another terminal says who holds the lock, waits
# in line while the holder runs, and runs once the holder exits.

Source test/e2e/setup.tape

# Top: hold the lock until cat sees end of input
Type "nlock run gpu -- cat" Enter
Sleep 0.5

# Middle: queue behind it, and hear who holds the lock
Ctrl+B
Down
Type "nlock run gpu -- echo second-job-ran" Enter
Wait+Screen@5s /nlock: waiting for 'gpu' . held by pid \d+ for \d\d:\d\d: cat \(next in line\)/

# Bottom: the holder is listed with one waiter
Ctrl+B
Down
Type "nlock list" Enter
Wait+Screen@5s /gpu\s+\d+\s+\d\d:\d\d\s+1\s+exclusive\s+-\s+cat/

# Top: end cat's input, releasing the lock to the waiter
Ctrl+B
Up
Ctrl+B
Up
Ctrl+D
Wait+Screen@5s /(?m)^second-job-ran/

# Bottom: nothing is held any more
Ctrl+B
Down
Ctrl+B
Down
Type "nlock list | wc -l | tr -d ' ' | sed 's/^/list-lines=/'" Enter
Wait+Screen@5s /(?m)^list-lines=1$/
