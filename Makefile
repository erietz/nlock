.PHONY: build
build:
	zig build

.PHONY: test
test:
	zig build test

.PHONY: test-integration
test-integration:
	zig build test-integration

.PHONY: test-all
test-all: test test-integration

.PHONY: test-tmux
test-tmux:
	COMMAND="sh -c 'echo testing && sleep 3'" NLOCK_LOG_LEVEL=Debug ./tmux_tests.sh
