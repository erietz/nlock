# Records docs/demo/rate.gif. Requires vhs, tmux, watch and a running nlockd.
#   zig build && vhs docs/demo/rate.tape   (run from the repository root)
# Uses the nlock just built in zig-out/bin, so the gif shows this checkout's
# `nlock list`. Lock 's' must not have been used in the last 10 seconds.

Output docs/demo/rate.gif

Require tmux
Require watch

Set Shell bash
Set FontSize 17
Set Width 1400
Set Height 700
Set Padding 16
Set Theme { "name": "isocon-dark", "black": "#062329", "red": "#e34b87", "green": "#419658", "yellow": "#ba783e", "blue": "#408cbd", "magenta": "#976fe3", "cyan": "#3e8c7e", "white": "#868686", "brightBlack": "#565656", "brightRed": "#f81486", "brightGreen": "#109b48", "brightYellow": "#c7700e", "brightBlue": "#0f8dcd", "brightMagenta": "#9c61fc", "brightCyan": "#0f907f", "brightWhite": "#868686", "background": "#062329", "foreground": "#868686", "selection": "#868686", "cursor": "#868686" }
Set TypingSpeed 45ms

Hide
Type `export PATH="$PWD/zig-out/bin:$PATH" && cd docs/demo && tmux -L nlock-rate-demo -f tmux.conf new-session \; split-window -v -l 22 \; select-pane -t 0` Enter
Sleep 1.5
Show

# Top: watch the lock. -t leaves out watch's header, which shows the hostname.
Type "watch -t -n 0.5 nlock list" Enter
Sleep 1

# Bottom: ten 5-second jobs, but at most 7 may start in any 10 seconds
Ctrl+B
Type "o"
Type "for i in {1..10}; do nlock run -s --rate 7/10s s -- sleep 5 & done" Enter

# 7 run and 3 wait. Enter brings the prompt back under the waiting messages,
# and after each batch finishes it shows bash's Done notices for it.
Sleep 1.5
Enter

# At 5s the 7 are done, but the 3 wait until their starts are 10s old
Sleep 5
Enter

# At 10s the 3 run; at 15s they are done, and their starts count until 20s
Sleep 10
Enter
Sleep 2.5

Hide
Type "tmux -L nlock-rate-demo kill-server" Enter
