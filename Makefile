build:
	zig build

test:
	zig build test

test-integration:
	zig build test-integration

test-all: test test-integration

test-tmux:
	COMMAND="sh -c 'echo testing && sleep 3'" NLOCK_LOG_LEVEL=Debug ./tmux_tests.sh
