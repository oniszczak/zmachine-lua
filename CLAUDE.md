# Working notes

A Z-machine **version 3** interpreter in pure Lua (`zm/`), plus a KOReader
plugin that embeds it (`zmachine.koplugin/`). See README.md for what it is and
how to use it; this file is about working on it.

## Before testing or installing, always

```sh
./tools/sync.sh                  # zm/ -> zmachine.koplugin/zm/
luajit tools/test_plugin.lua     # plugin control flow, stubbed KOReader
luajit tools/test_coroutine.lua  # the VM driven as the plugin drives it
```

**The plugin bundles its own copy of `zm/`.** It has silently drifted from the
canonical `zm/` once already, and the tests then passed against stale code.
`sync.sh` is not optional.

## Never guess a KOReader API

There is **no macOS build of KOReader** (the Homebrew cask is Linux-only), so
the plugin UI cannot be run locally. Check every widget field and method
against the source at the version the device runs:

```
https://raw.githubusercontent.com/koreader/koreader/v<VERSION>/frontend/ui/widget/<widget>.lua
```

`koreader/git-rev` on the device gives `<VERSION>`. One pass of this caught
three wrong fields. Guessing has cost two on-device crashes.

`tools/test_plugin.lua` stubs KOReader's modules and drives the real
interpreter, so plugin logic *can* be tested headlessly. Extend it rather than
shipping and hoping — it caught an `lfs.dir` misuse that crashed KOReader.

`lfs.dir` returns **two** values (iterator *and* directory handle). Wrapping it
in `pcall` and keeping only the first breaks the loop.

## Design decisions to preserve

- **Save/Load buttons send the game its own `save`/`restore` commands.** Do not
  add an independent snapshot mechanism. The two capture different resume
  points — the game's is inside the save instruction, a prompt snapshot is at
  `sread` — and cross-loading resumes mid-instruction and corrupts the session.
- **Pure Lua, no FFI, no native code.** This is what lets one plugin run on
  every KOReader target including ARMv6. Don't introduce a C dependency.
- The VM is synchronous; the plugin runs it in a **coroutine** whose
  `read_line` yields. Keep `Machine` free of UI concerns.
- Only dynamic memory (below `static_base`) is mutable, and it's the only thing
  a save has to capture besides pc/stack/frames.

## Debugging on device

KOReader writes `koreader/crash.log`; an uncaught Lua error there names the
file and line. Plugin entry points are wrapped in `ZMachine:guard()` so faults
surface as a message instead of taking KOReader down — keep new entry points
wrapped.

When copying to a Kindle or Kobo from macOS, run `dot_clean -m <volume>`
afterwards; AppleDouble `._` files cause real problems on these devices.
