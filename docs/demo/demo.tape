# Records docs/demo/demo.gif. Requires vhs, tmux and a running nlockd.
#   vhs docs/demo/demo.tape   (run from the repository root)

Output docs/demo/demo.gif

Require tmux
Require nlock

Set Shell bash
Set FontSize 17
Set Width 1400
Set Height 480
Set Padding 16
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms

Hide
Type "cd docs/demo && tmux -L nlock-demo -f tmux.conf new-session \; split-window -v -l 6 \; select-pane -t 0 \; split-window -h \; select-pane -t 0" Enter
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
Sleep 10

Hide
Type "tmux -L nlock-demo kill-server" Enter
