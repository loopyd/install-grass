## Command-Line Usage

```sh
getgrass.sh [action] [options]
```

### Actions

| Action     | Description                             |
|------------|-----------------------------------------|
| `install`  | Install the Grass Desktop Node          |
| `uninstall`| Uninstall the Grass Desktop Node        |

### Menu Options

| Short | Long | Type | Description |
| ---- | ----------- | ---------- | -------------------- |
| `-h` | `--help` | switch | Display the help message, and exit            |

For more information, you can run `-h` or `--help` for usage instructions on each action.

## `install` Action

```sh
getgrass.sh install [options]
```

This action allows you to install the Grass Desktop Node onto your system.

### Installer options

| Short | Long | Type | Description |
| ---- | ----------- | ---------- | -------------------- |
| `-h` | `--help` | switch | Display the help message, and exit |
| `-c` | `--config-file` | file | Configuration file to use |
| `-i` | `--install-prefix` | dir | Installation prefix, install in this directory rather than the defaults |
| `-e`| `--cache-dir` | dir | Cache directory for storing downloaded files; important for uninstallation |
| `-u` | `--user-mode` | switch | Install in user mode, owned by the user |
| `-d` | `--debug` | switch | Enable debug mode, display debug information |
| `-x` | `--no-logging` | switch | Disable logging |
| `-l` | `--log-file` | file | Log file to use; ignored if `-x` is specified |
| `-q` | `--quiet` | switch | Quiet mode, no terminal output |
| `-z` | `--no-logo` | switch | Disable the logo display |
| `-D` | `--dry-run` | switch | Dry run mode, show steps without installing; downloads still occur into the cache directory |

## `uninstall` Action

```sh
$0 uninstall [options]
```

This action allows you to remove the Grass Desktop node from your system.

> ⚠️ This action is dependent on you having used the ``install`` action first.  If you've used the .deb package, this action won't work.

### Uninstaller Options

| Short | Long | Type | Description |
| ---- | ----------- | ---------- | -------------------- |
| `-h` | `--help` | switch | Display the help message, and exit |
| `-c` | `--config-file` | file | Manifest configuration file to use |
| `-i` | `--install-prefix` | dir | Installation prefix, where you had installed the Grass Node to |
| `-e`| `--cache-dir` | dir | Cache directory to reference for uninstallation. |
| `-d` | `--debug` | switch | Enable debug mode to display extra debugging information |
| `-x` | `--no-logging` | switch | Disable logging |
| `-l` | `--log-file` | file | Log file to use; ignored if `-x`/`--no-logging` is specified |
| `-q` | `--quiet` | switch | Use quiet mode to surpress all terminal output |
| `-z` | `--no-logo` | switch | Disable the logo display |
| `-D` | `--dry-run` | switch | Dry run mode, show steps without uninstalling; downloads still occur into the cache directory |