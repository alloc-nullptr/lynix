# Lynix Proton Wrapper

A standalone Bash launcher for a **user-supplied** `UI.exe` (Lynx). It runs the
app through GDK-Proton or GE-Proton and installs the Microsoft WebView2 and
Visual C++ runtimes into a private Proton prefix.

- No Steam installation is required.
- `UI.exe` is not included, copied, downloaded, or embedded by this project.
  The script asks you to select your own copy on first run.
- WebView2 and the VC++ runtime are downloaded and installed automatically.

## Quick start

Run the script directly:

```sh
./lynix-proton.sh
```

Or pipe it straight from a URL:

```sh
curl -fsSL https://raw.githubusercontent.com/alloc-nullptr/lynix/refs/heads/main/lynix-proton.sh | bash
```

When piping, pass options after `bash -s --`:

```sh
curl -fsSL https://raw.githubusercontent.com/alloc-nullptr/lynix/refs/heads/main/lynix-proton.sh | bash -s -- --setup
curl -fsSL https://raw.githubusercontent.com/alloc-nullptr/lynix/refs/heads/main/lynix-proton.sh | bash -s -- --exe /path/to/UI.exe --proton /path/to/Proton
```

Prompts are read from the controlling terminal (`/dev/tty`), so the
`curl ... | bash` form stays interactive. In a graphical session the script can
use `zenity`, `kdialog`, or `yad` instead.

### Save the script first

A saved copy is easier to re-run and is required for the application-menu
shortcut:

```sh
curl -fsSL https://raw.githubusercontent.com/alloc-nullptr/lynix/refs/heads/main/lynix-proton.sh -o ~/.local/bin/lynix-proton.sh
chmod +x ~/.local/bin/lynix-proton.sh
~/.local/bin/lynix-proton.sh
```

If you create the shortcut from a piped run, also set `LYNIX_SCRIPT_URL` so the
script can keep a copy of itself:

```sh
curl -fsSL "$URL" | LYNIX_SCRIPT_URL="$URL" bash -s -- --install-desktop
```

## What it does

1. Asks for your `UI.exe` (or uses `--exe PATH`) and saves the choice.
2. Finds an installed GDK-Proton, GE-Proton, or Steam Proton build.
   If none exists, it offers to download one into its private data folder.
3. Creates a private Proton prefix that does not depend on Steam.
4. Installs the x64 Visual C++ runtime and the WebView2 runtime into that
   prefix if they are missing.
5. Launches `UI.exe` through Proton.

The first setup downloads roughly 600 MB and needs about 3 GB of free disk
space. Later runs use the saved configuration.

## Options

```
-h, --help                 Show help and exit
--select, --change-exe     Select UI.exe again (file picker)
--exe PATH                 Use PATH as UI.exe
--proton PATH              Use the Proton build in PATH
--download-proton FLAVOR   Download GDK-Proton (gdk) or GE-Proton (ge)
--setup                    Install/configure everything, do not launch
--status                   Show the current configuration
--install-desktop          Create an application-menu shortcut
--uninstall                Remove the shortcut and wrapper settings
--purge                    With --uninstall, also delete private data
--no-gui                   Never use zenity/kdialog; prompt in the terminal
--debug                    Keep verbose Proton/Wine output
--reset                    Forget saved choices, then run
--version                  Print the version
```

Pass arguments to `UI.exe` after `--`:

```sh
./lynix-proton.sh -- --some-flag
```

## Data locations

| What | Default path |
| --- | --- |
| Settings | `$XDG_CONFIG_HOME/lynix-proton/config` |
| Prefix, Proton, cache, logs | `$XDG_DATA_HOME/lynix-proton` |
| Launcher log | `$XDG_DATA_HOME/lynix-proton/logs/launcher.log` |

Override them with `LYNIX_CONFIG_DIR` and `LYNIX_DATA_DIR`.

## Troubleshooting

Show the current setup:

```sh
./lynix-proton.sh --status
```

Read the launcher log:

```sh
tail -n 100 ~/.local/share/lynix-proton/logs/launcher.log
```

If the app was force-killed and a later start exits immediately, remove the
stale IPC files and try again:

```sh
rm -f ~/.local/share/lynix-proton/prefix/pfx/drive_c/Lynx/mcp/endpoint.json
rm -f ~/.local/share/lynix-proton/prefix/pfx/drive_c/Lynx/port
```

The wrapper does this automatically when it starts a new instance.

## Requirements

- Linux with a working Vulkan driver (AMD, Intel, or NVIDIA)
- Bash 4.3 or newer
- `curl` or `wget`, plus `tar`
- Optional: `zenity`, `kdialog`, or `yad` for graphical prompts

## Legal

`UI.exe` is licensed software and belongs to its author. This project only
provides a launcher; it does not distribute the application.

big thanks to deepseek
