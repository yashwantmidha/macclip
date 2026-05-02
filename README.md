# MacClip

Lightweight clipboard history manager for macOS with a global hotkey picker.

## Features

- Menu bar app with global hotkey (default `Option + V`)
- Searchable clipboard history
- Paste on row click
- `Enter` to copy selected item
- `Cmd + Enter` or double-click to paste selected item
- Per-item actions: copy (`📋`), pin/unpin (`📌`/`📍`), delete (`🗑`)
- Configurable history limit (`10/20/30/40/50`)
- In-memory history only (no clipboard file storage)
- Optional autostart at login

## Install

```bash
npm i -g macclip
macclip install
```

Install with login autostart:

```bash
macclip install --autostart
```

## Use

Open clipboard history:

```bash
Option + V
```

In picker:

- Click a row: paste
- Enter: copy selected item
- Cmd + Enter: paste selected item
- Double-click a row: paste selected item
- Use row buttons:
  - `📋` copy
  - `📌`/`📍` pin or unpin
  - `🗑` delete

Useful commands:

```bash
macclip start
macclip stop
macclip status
macclip autostart on
macclip autostart off
macclip uninstall
```
