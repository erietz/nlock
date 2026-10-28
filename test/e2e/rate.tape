# --rate in a terminal: -n over the limit says when the next run is allowed,
# a blocking request says it waits for the limit, nlock list shows the limit
# while nobody holds the lock, and the waiter runs once the window passes.

Source test/e2e/setup.tape

# Top: use up the limit, then get turned away without waiting
Type "nlock run --rate 1/5s api -- echo call-1" Enter
Wait+Screen@5s /(?m)^call-1/
Type "nlock run -n --rate 1/5s api -- echo call-2; echo status=$?" Enter
Wait+Screen@5s /nlock: 'api' has reached its limit of 1\/5s; next run allowed in \ds/
Wait+Screen@5s /(?m)^status=75/

# Middle: wait for the limit
Ctrl+B
Down
Type "nlock run --rate 1/5s api -- echo call-3" Enter
Wait+Screen@5s /nlock: waiting for 'api' . limit of 1\/5s reached \(next in line\)/

# Bottom: listed with no holder, one waiter, and the limit used up
Ctrl+B
Down
Type "nlock list" Enter
Wait+Screen@5s /RATE\s+USED\s+CMD/
Wait+Screen@5s /api\s+-\s+-\s+1\s+-\s+\S+\s+1\/5s\s+1\s+-/

# Middle: runs once call-1 falls out of the window
Wait+Screen@8s /(?m)^call-3/
