# midx.nvim

A Neovim plugin for live editing [midx](https://github.com/123Untitled/midx) files with real-time MIDI feedback and syntax highlighting.


## Features

- 🎵 **Live Hot Reload** - Changes are sent to MIDX server in real-time without manual saves
- 🎨 **Real-time Syntax Highlighting** - Active musical elements are highlighted during playback
- ⚡ **Inline Diagnostics** - Parser and lexer errors displayed inline with native Neovim diagnostics
- 🎹 **Play/Pause Control** - Toggle playback directly from the editor
- 📊 **Status Bar** - Visual feedback with connection status, playback state, and errors
- 🔄 **Auto-reconnection** - Automatically reconnects to MIDX server if connection is lost
- 📝 **Smart Indentation** - Context-aware indentation for MIDX syntax


## Requirements

- Neovim >= 0.8.0
- [midx](https://github.com/123Untitled/midx) server running


## Installation

#### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  '123Untitled/midx',
  ft = 'midx',  -- Lazy load on .midx files
  config = function()
    require('midx').setup()
  end,
}
```

#### [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  '123Untitled/midx',
  ft = 'midx',
  config = function()
    require('midx').setup()
  end,
}
```

#### Manual

Clone to your Neovim config directory:

```bash
git clone https://github.com/123Untitled/midx ~/.config/nvim/pack/plugins/start/midx.nvim
```

Then add to your `init.lua`:

```lua
require('midx').setup()
```


## Configuration

The plugin works out of the box with sensible defaults. Simply call `setup()`:

```lua
require('midx').setup()
```

### Default Settings

- **Socket path**: `/tmp/midx.sock`
- **Auto-reconnect interval**: 100ms
- **Filetype detection**: Automatic for `.midx` files


## Usage

#### Commands

| Command           | Description                    |
|-------------------|--------------------------------|
| `:MidxTogglePlay` | Toggle play/pause              |
| `:MidxSwitch`     | Switch active buffer           |
| `:MidxStatus`     | Display connection status      |

#### ⌨ Keybindings

| Key       | Mode   | Action            |
|-----------|--------|-------------------|
| `<space>` | Normal | Toggle play/pause |

#### 🚀 Workflow

1. Start the MIDX server:
   ```bash
   ./midx
   ```

2. Open a `.midx` file in Neovim:
   ```bash
   nvim hello.midx
   ```

3. The plugin automatically:
   - Connects to the MIDX server at `/tmp/midx.sock`
   - Sends buffer content to the server
   - Enables live editing and syntax highlighting

4. Edit your `.midx` file - changes are sent in real-time

5. Press `<space>` to toggle playback

6. Active tokens are highlighted during evaluation


## How It Works

### Architecture

```
┌─────────────────┐         Unix Socket         ┌──────────────────┐
│                 │ ◄────────────────────────── │                  │
│  Neovim Plugin  │       /tmp/midx.sock        │   MIDX Server    │
│                 │                             │                  │
└─────────────────┘                             └──────────────────┘
        │                                                │
        ├─ Buffer management                             ├─ Parser/Lexer
        ├─ Highlight rendering                           ├─ AST Evaluator
        ├─ Diagnostic display                            ├─ MIDI Engine
        └─ Auto-reconnection                             └─ Highlight Tracker
```

### Communication Protocol

**Outgoing** (Neovim → MIDX):
- `UPDATE<size>\n<content>` - Send buffer updates
- `TOGGLE\n` - Toggle play/pause

**Incoming** (MIDX → Neovim):
- JSON messages with syntax highlights
- JSON messages with animation highlights
- JSON messages with diagnostics

## Status Bar

The plugin displays a winbar at the top of `.midx` buffers showing:

- **Connection indicator**: ● (connected) / ○ (disconnected)
- **Playback state**: ▶ PLAYING / ⏸ PAUSED
- **Error indicator**: ⚠ Error (if any)
- **Retry counter**: (retry N) when reconnecting

## 🌈 Highlight Groups

The plugin defines custom highlight groups that link to standard Neovim groups:

| Group              | Links to    | Purpose                |
|--------------------|-------------|------------------------|
| `MidxBrand`        | `Normal`    | Branding text          |
| `MidxConnected`    | `String`    | Connected indicator    |
| `MidxDisconnected` | `Error`     | Disconnected indicator |
| `MidxPlaying`      | `Keyword`   | Playing state          |
| `MidxPaused`       | `Normal`    | Paused state           |
| `MidxInfo`         | `WarningMsg`| Info messages          |
| `MidxError`        | `ErrorMsg`  | Error messages         |

You can override these in your colorscheme if desired.
