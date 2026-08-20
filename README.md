# Cockpit Board Companion

Read-only Omarchy bar widget for the Obsidian `cockpit-board` plugin.

![Preview](preview.png)

## What it does

- Shows a compact week view that can expand to a month grid
- Lists the selected day's tasks in cockpit-board order
- Highlights overdue tasks
- Shows optional checklist progress meters for selected task files
- Runs a task-attached pomodoro timer without writing back to the vault

## Requirements

- Omarchy / Quickshell plugin support
- Obsidian installed locally
- The Obsidian `cockpit-board` plugin: https://github.com/andreconde21/cockpit-board
- A cockpit-board vault with tasks stored in `Tasks/Active/*.md`

## Configuration

The main setting is `vaultDir`, which should point at the root of your cockpit-board vault.

Default settings:

```json
{
  "vaultDir": "~/Obsidian",
  "refreshIntervalSec": 60,
  "workMinutes": 25,
  "breakMinutes": 5,
  "checklistPatterns": ""
}
```

`checklistPatterns` accepts comma-separated filename globs relative to `Tasks/Active`, for example `weekly-review*,launch-plan`.

## Coupling to cockpit-board

This plugin is intentionally specific to `cockpit-board`.

- It reads task files from the vault layout expected by `cockpit-board`
- It mirrors `cockpit-board` card ordering via frontmatter `order:`
- It reads pomodoro defaults from `.obsidian/plugins/cockpit-board/data.json`
- It surfaces `pomodoros` and `time_spent` values tracked by `cockpit-board`

If you are not using `cockpit-board`, this plugin is probably not the right fit.

## Privacy

This plugin is read-only. It scans vault files and keeps temporary pomodoro state in `XDG_RUNTIME_DIR`. It never writes to the Obsidian vault.

## Install

```bash
omarchy plugin add <repo-url> --enable --yes
```

Or copy the directory into `~/.config/omarchy/plugins/andreconde.cockpit/` and run:

```bash
omarchy-shell shell rescanPlugins
omarchy plugin enable andreconde.cockpit
```

## Remove

```bash
omarchy plugin remove andreconde.cockpit
```

If you installed it by copying the directory manually, delete `~/.config/omarchy/plugins/andreconde.cockpit/`, then run:

```bash
omarchy-shell shell rescanPlugins
```
