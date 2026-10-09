# Installation

## From source (user installation)

To install from source:

1. Clone the repository:
    ```bash
    git clone https://github.com/erietz/nlock.git
    cd nlock

    # Trust the mise.toml file
    mise trust
    # Install the dependencies
    mise install
    # Build and install to ~/.local as the prefined prefix
    mise run install
    ```
2. Start the nlockd service:
    1. Linux:
        ```bash
        mise run daemon-systemd-user-start
        ```
    2. macOS:
        ```bash
        mise run daemon-macos-user-start
        ```

If you do not have `mise` installed, view the commands in `./mise.toml` and run
them manually.
