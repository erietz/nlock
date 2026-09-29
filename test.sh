#!/usr/bin/env bash

set -euo pipefail

zig build

# open a new tmux window and split the window into two panes
tmux new-window -n "Test Window"

# Split the window into two panes
tmux split-window -h

# Start the server in the left pane
tmux send-keys -t 1 "./zig-out/bin/nlockd" C-m

# Split the right pane into two panes
tmux split-window -v -t 2

# Split the right pane into three panes
tmux split-window -v -t 3

# Wait for the server to start
sleep 2

# Send a command to the right pane from the client
tmux send-keys -t 2 "./zig-out/bin/nlock run test -- sleep 3" C-m
sleep 1

# Send a command to the bottom right pane from the client
tmux send-keys -t 3 "./zig-out/bin/nlock run test -- sleep 3" C-m
sleep 1

# Send a command to the bottom right pane from the client
tmux send-keys -t 4 "./zig-out/bin/nlock run test -- sleep 3" C-m
