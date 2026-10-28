# Shared by every tape: a wide terminal running tmux with three panes
# stacked top to bottom, so no line wraps, and the top pane selected.
# Move between panes with Ctrl+B then Up or Down.

Require tmux
Require nlock

Set Shell bash
Set FontSize 14
Set Width 1600
Set Height 900
Set TypingSpeed 5ms

Type `tmux -S "$E2E_TMUX" -f test/e2e/tmux.conf new-session \; split-window -v \; split-window -v \; select-layout even-vertical \; select-pane -t 0` Enter
Sleep 1
