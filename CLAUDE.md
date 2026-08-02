# CLAUDE.md — midx.nvim

This repo is the **NeoVim plugin**: the live-editing client for `.midx` files
and the **client half** of the binary socket protocol. It is **authoritative**
for the plugin's module architecture, the protocol client (FFI mirror), and the
animation engine.

> **Paths** in this file are relative to **this repo root** (`midx.nvim/`).
> Launched from the midx workspace, Claude loads this file when you touch files
> here. From the workspace root, prefix a path with `midx.nvim/` (see the
> workspace `CLAUDE.md` map). The **shared wire contract** lives in the
> workspace `CLAUDE.md`; the **server half** of the protocol lives in
> `midx.server/CLAUDE.md` — the two must stay in lockstep.

## Overview

~2,000 lines of Lua across `lua/midx/` (11 modules) + `lua/midx/protocol/` (3) +
`plugin/midx.lua`. Formatted with `stylua` (tabs, per `stylua.toml`). Requires
Neovim ≥ 0.8 (uses LuaJIT FFI for decoding).

- **Language:** Lua (LuaJIT — the decoder relies on `ffi`)
- **Purpose:** Live editing of `.midx` files with real-time feedback from the
  running midx server
- **Socket:** Connects to `/tmp/midx.sock` (Unix domain socket, async libuv pipe
  via `vim.uv or vim.loop`)
- **Protocol:** **binary in BOTH directions** (the JSON path is gone). See
  Protocol below.

## Module architecture (one connection per buffer)

Session-per-buffer. Layered, acyclic dependency graph (`buffer → {session,
update, syntax, animation, diagnostic, diff}`, `update → {syntax, diagnostic,
animation, session, mirror}`, `session → {connection, encoder, decoder,
event}`):

```
plugin/midx.lua   — filetype registration (loads before lazy-load)
lua/midx/
  init.lua        — Orchestrator: setup(), autocmds/commands/keymaps, shutdown()
  event.lua       — Pub/sub emitter (on/emit) — only 'state:changed' is used
  connection.lua  — connection.new() factory: async libuv pipe, connect/disconnect/send +
                    on_data/on_connected/on_disconnected callbacks, EOF→retry (250ms interval)
  session.lua     — Per-buffer registry sessions[bufnr]={conn,decoder,is_connected,is_playing,
                    revision,generation}; state (get/set_state → emits state:changed), transport
                    (attach/detach), sends (send_buffer/send_toggle/send_diff), is_attached
  buffer.lua      — Per-buffer edit LIFECYCLE: attach/detach (opens session + byte tracking +
                    cover + commentstring; cleans all renders on detach). Owns nvim_buf_attach
                    (on_bytes → diff → session.send_diff, on_reload → send_buffer)
  update.lua      — Coordinator for server updates: gen_state[bufnr]={tokens,comments}; provides
                    the decoder handlers (update.handlers(bufnr)); resolves token ids → positions;
                    routes to syntax/diagnostic/animation. THE client counterpart of server session
  syntax.lua      — Static syntax render: tokens+comments → extmarks; dim variants (MidxDim<G>);
                    cover() = base "Comment" layer; clear(); owns the sx→group mapping via mirror
  diagnostic.lua  — apply(entries)→vim.diagnostic (one entry per chunk); generic msg per an::code
  animation.lua   — Execution fade engine (see below)
  background.lua  — Resolves fade-target bg: Normal.bg → OSC 11 async → fallback; ColorScheme-aware
  diff.lua        — from_bytes(on_bytes args) → byte-splice record {offset,removed,added,text};
                    cursor(). Handles trailing-newline / pure-deletion edge cases
  protocol/
    decoder.lua   — bytes → Lua tables. Framing state machine (header/payload/resync) + the
                    IMMEDIACY GATE + 5 payload decoders. FFI casts (mirror of syntax.h structs)
    encoder.lua   — outgoing messages: encoder.buffer/.toggle/.diff (header + payload, LE)
    mirror.lua    — server-enum mirrors "must match": GROUPS[sx::id], CODES[an::code], SEVERITY
```
Removed since the JSON era: `highlights.lua` (→ split into `syntax`+`diagnostic`),
`protocol.lua` (→ `protocol/encoder.lua`), `statusline.lua` (no winbar/status
indicator today).

## Lifecycle & buffer wiring

`plugin/midx.lua` registers the `.midx` filetype. `require('midx').setup()`
(`init.lua`) wires `background/syntax/animation.setup()`, the `state:changed`
listener, and `MidxAutocmds`:
- **`FileType midx`** → `buffer.attach(bufnr)` (session + byte tracking +
  `syntax.cover` + `commentstring = '\\ %s'`).
- **`BufUnload *.midx`** → `buffer.detach(bufnr)` (+ clears the `last_tick` dedup
  map).
- **`TextChanged`/`TextChangedI`** → `session.send_buffer` + `syntax.cover`
  (deduped per buffer via `b:changedtick`).

Commands: **`:MidxTogglePlay`**, **`:MidxStatus`**. Keymap: normal **`<space>`**
→ `:MidxTogglePlay` (currently a GLOBAL map — intrusive, flagged to become
buffer-local). `require('midx').shutdown()` tears down the shared animation
engine (call before a hot reload that clears `package.loaded`; normal `setup()`
re-runs are idempotent).

### Dual send (transitional)

Every edit sends BOTH a full `buffer` (TextChanged) AND byte `diff`s (on_bytes),
in parallel. The server does not apply diffs yet (it only prints them), so the
diff path is currently validated-but-unused overhead; the buffer path is
authoritative. To be collapsed to diffs-only once the server applies them.

## Generation model & the immediacy gate

The **client owns the authoritative generation** — `sessions[bufnr].generation`,
an outgoing counter bumped on each buffer send. The server adopts it (via the
header) and echoes it in every `update`.

The **immediacy gate lives in the decoder** (`decoder.lua`): a position-bearing
frame (`syntax`/`live`/`diagnostic`) whose header generation ≠ the client's
current generation is **dropped before the payload is decoded** — nvim has
already moved past that buffer state (immediacy: the render never reflects
superseded text). `clock`/`state` carry no buffer positions → **exempt** (a
stale one is still correct; dropping would lose one-shot sync / session state).
`session.attach` injects the current-generation accessor into `decoder.new`.

`revision` is a finer granularity BELOW generation: reset to 0 on a buffer send,
bumped on each diff — the diff-count since the current baseline. Together
`(generation, revision)` identify a buffer state (needed once the server applies
diffs).

## Animation fade engine (`animation.lua` + `background.lua`)

A **decoration provider** places EPHEMERAL extmarks (recomputed each redraw,
viewport-limited), so the color is never recolored per frame: precomputed **step
groups** `MidxFade_<accent>_<step>` (STEPS=128, bg→accent gradient, shared across
buffers, keyed by accent color + step, version-invalidated on ColorScheme/bg
change) — the provider picks the step nearest the current combined alpha. A
**single global ~60 fps timer** (`FRAME_MS=16`) purges expired sources and pumps
redraws; it self-stops at `count==0`. `M.setup()` is idempotent (calls
`M.shutdown()` first).

Registry is **token-keyed, multi-chunk**: `anim[bufnr][token_id] = { ranges=[{ln,
cs,ce}], accent, sources=[{onset,dur}] }` — ONE fade per token covering all its
chunks; `rowmap[bufnr][row][token_id]` indexes every chunk's row. A fire
references a token id; `update.live` resolves it (positions + group) against
`gen_state`, converts `dur` µs→ns. Fades are **wiped entirely on a new
generation** (`update.syntax` calls `animation.clear`) — they never survive a
reparse; positions are captured at creation. `clock` update → `animation.sync`
(offset = client − server ns). `background.lua` supplies the fade target from
`Normal.bg` else async **OSC 11** (via `TermResponse`), ColorScheme-aware.

## Protocol (binary both directions) — client side

Shared 16-byte header (mirror of `pc::header`): `"MIDX"(4) + generation(4) +
opcode(4) + length(4)`, all `u32` **little-endian**.

**Outgoing** (`encoder.lua`, `pc::control` enum): `buffer`=0, `diff`=1, `play`=2,
`stop`=3, `toggle`=4, `state`=5. Emitted today: `buffer` (source), `diff`
(byte-splice: 6×u32 revision/offset/removed/added/cursor_row/cursor_col + text),
`toggle` (zero-length).

**Incoming** (`decoder.lua`, `pc::update` enum): `syntax`=0, `comment`=1
(reserved; comments ride in the syntax tail), `live`=2, `diagnostic`=3,
`clock`=4, `state`=5. The decoder frames the stream (resync on bad magic),
applies the immediacy gate, then FFI-decodes each payload to Lua tables (ids
arrive 0-based → converted to **1-based**; coordinates are `{ln,cs,ce}`
everywhere):
- `syntax` — preamble `{tokens, comments}` then **interleaved** (token then its
  `chunks` chunk records), comments in the tail. Token = `{group(sx::id), dimmed,
  chunks=[{ln,cs,ce}]}` → `update.handlers.syntax`.
- `live` — `epoch{when(ns)}` + fire records `{id(token), dur(µs)}` →
  `update.handlers.live`.
- `diagnostic` — records `{token, code(an::code), level, extra}` →
  `update.handlers.diagnostic`.
- `clock` — `{now(ns)}` → `animation.sync`. `state` — `{flags:bit0=playing}` →
  `session.set_state`.

Malformed payloads are dropped + logged; the framing stays sound (no resync).
The wire struct layouts are asserted at load (`ffi.sizeof`). The server half
(struct definitions, serialization) lives in `midx.server/CLAUDE.md` — a change
to any struct layout or opcode touches both repos.

## Highlight groups

- **`MidxDim<G>`** — derived dimmed variant of a semantic group `G` (`syntax.lua`):
  keeps hue, blends the fg toward the background (`DIM_BLEND`), gui + cterm
  (xterm-256), lazily built, cache cleared on ColorScheme.
- **`MidxFade_<accent>_<step>`** — precomputed fade gradient steps
  (`animation.lua`), background→accent.

`sx::id → group name` mapping (`mirror.GROUPS`, must match server `sense.h`):
`none`/`comment`→`Comment`, `define`→`Define`, `symbol`→`Identifier`,
`keyword`→`Keyword`, `type`→`Type`, `function`→`Function`, `op`→`Operator`,
`delimiter`→`@punctuation.bracket`, `number`→`Number`, `string`→`String`.

## Code Style

- **Formatting:** `stylua` (tabs, per `stylua.toml`).
- **Coordinates:** `{ln, cs, ce}` (line, col-start, col-end) everywhere; ids are
  **1-based** on the Lua side (converted in the decoder from the server's 0-based).
- **Never trust the server:** position-bearing renders (`syntax.apply`) keep a
  `pcall` around each extmark so one bad range can't abort the whole repaint (a
  commented fast-path exists for when the server is trusted — see the WARNING in
  `syntax.lua`).
