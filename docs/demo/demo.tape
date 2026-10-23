# Records docs/demo/demo.gif. Requires vhs, tmux and a running nlockd.
#   vhs docs/demo/demo.tape   (run from the repository root)

Output docs/demo/demo.gif

Require tmux
Require nlock

Set Shell bash
Set FontSize 17
Set Width 1400
Set Height 600
Set Padding 16
Set Theme { "name": "isocon-dark", "black": "#062329", "red": "#e34b87", "green": "#419658", "yellow": "#ba783e", "blue": "#408cbd", "magenta": "#976fe3", "cyan": "#3e8c7e", "white": "#868686", "brightBlack": "#565656", "brightRed": "#f81486", "brightGreen": "#109b48", "brightYellow": "#c7700e", "brightBlue": "#0f8dcd", "brightMagenta": "#9c61fc", "brightCyan": "#0f907f", "brightWhite": "#868686", "background": "#062329", "foreground": "#868686", "selection": "#868686", "cursor": "#868686" }
Set TypingSpeed 45ms

Hide
Type "cd docs/demo && tmux -L nlock-demo -f tmux.conf new-session \; split-window -v -l 12 \; select-pane -t 0 \; split-window -h \; select-pane -t 0" Enter
Sleep 1.5
Show

# Left pane: grab the GPU
Type "nlock run gpu -- ./train.sh small" Enter
Sleep 1

# Right: a second job, from another terminal, queues behind it
Ctrl+B
Type "o"
Type "nlock run gpu -- ./train.sh large" Enter
Sleep 1.5

# Bottom: who holds the lock, and who is waiting
Ctrl+B
Type "o"
Type "nlock list" Enter
Sleep 3.5

# The first job is done: the second holds the lock, nobody waits
Type "nlock list" Enter
Sleep 4.5

# Both are done: no locks held
Type "nlock list" Enter
Sleep 3

Hide
Type "tmux -L nlock-demo kill-server" Enter
