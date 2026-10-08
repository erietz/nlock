# Service definitions

Templates for running `nlockd` as a per-user daemon. `zig build install`
fills in `@bindir@` and installs the right one for the target OS:

| Template | Installed as |
|---|---|
| `systemd/nlockd.service.in` | `<prefix>/share/systemd/user/nlockd.service` (Linux) |
| `launchd/com.erietz.nlockd.plist.in` | `<prefix>/share/nlock/launchd/com.erietz.nlockd.plist` (macOS) |

`@bindir@` defaults to `<prefix>/bin`. When building into a staging
directory for a package, pass the final location instead:

    zig build install --prefix debian/nlock/usr -Dservice-bindir=/usr/bin

Neither file redirects nlockd's output: when stderr is not a terminal,
nlockd logs to syslog, which reaches the systemd journal and the macOS
unified log. See `nlockd(1)`, section LOGGING.

See `nlockd(1)`, section RUNNING NLOCKD AS A SERVICE, for how to enable them.

## Homebrew

Homebrew generates its own launchd plist (and systemd unit on Linux) from the
formula, so the formula should declare a service block rather than install
the files above:

```ruby
service do
  run opt_bin/"nlockd"
  keep_alive successful_exit: false
  process_type :background
end
```

Users then run `brew services start nlock`.
