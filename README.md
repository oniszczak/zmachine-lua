# zmachine-lua

A Z-machine (version 3) interpreter written in pure Lua, for playing
Infocom-era interactive fiction — and specifically for running it inside
KOReader on e-readers where cross-compiling a native interpreter isn't
practical.

Because it's pure Lua with no C dependencies, the same code runs on every
KOReader target: Kindle 3 (ARMv6), Kindle 4, Paperwhite, and Kobo, with no
toolchain involved.

## Layout

    zm/memory.lua     memory image, header, checksum, packed addresses
    zm/text.lua       ZSCII decoding: alphabets, shifts, abbreviations
    zm/objects.lua    object tree, attributes, properties
    zm/dict.lua       word encoding, dictionary lookup, input tokenising
    zm/machine.lua    instruction decode, opcodes, call frames, save/restore

    tools/inspect.lua        dump header, abbreviations, dictionary
    tools/play.lua           play a story in the terminal
    tools/test_coroutine.lua verify the coroutine drive model

    zmachine.koplugin/       the KOReader plugin (bundles a copy of zm/)

## Playing in a terminal

    luajit tools/play.lua ~/Downloads/KIF/hhgg.z3

## Inspecting a story file

    luajit tools/inspect.lua ~/Downloads/KIF/hhgg.z3

Verifies the story against its own header checksum, then dumps the
abbreviation table and dictionary — a quick way to confirm the text decoder
is behaving.

## Installing the KOReader plugin

Copy `zmachine.koplugin/` into KOReader's plugins directory:

    Kindle   /mnt/us/koreader/plugins/
    Kobo     .adds/koreader/plugins/

Put story files in your library folder, `koreader/stories`, or
`/mnt/us/stories`. Then: **KOReader menu → Interactive fiction**.

The game opens as one full-screen view: text accumulates, you type at the
bottom, Enter submits. Three buttons:

- **Save** — sends the game its own `SAVE` command
- **Load** — sends `RESTORE`
- **Exit** — asks for confirmation before leaving without saving

The buttons are not a separate mechanism: they do exactly what typing `save`
and `restore` does, so they share one file per story and behave identically.

Note that the Z-machine v3 `save` opcode takes no arguments — the game has no
concept of save slots at all. How many there are is the interpreter's choice,
and this one keeps a single file per story.

## Device compatibility

Pure Lua with no FFI or native code, so it runs on every KOReader target:
Kindle (`kindle-legacy` / `kindle` / `kindlepw2` / `kindlehf`), Kobo and Tolino
(`kobo` / `kobov5`), Android, PocketBook, Cervantes, reMarkable, and Linux
desktop.

The Kindle 3 — 256 MB, ARMv6 — is the slowest supported target and plays
comfortably, so nothing else should struggle.

Plugin directory by platform:

    Kindle   /mnt/us/koreader/plugins/
    Kobo     .adds/koreader/plugins/
    Android  koreader/plugins/ in app storage
    Linux    ~/.config/koreader/plugins/

Story files go in the library folder or `koreader/stories` (on Kobo that is
`.adds/koreader/stories`; `/mnt/us` does not exist there).

Tested on the Kindle 3. Other targets are compatible by construction rather
than by observation. Widget fields are verified against KOReader v2026.07.1;
an older KOReader may not have all of them.

## Scope

Version 3 only. That covers essentially the whole classic Infocom catalogue —
Zork I–III, Hitchhiker's, Planetfall, Enchanter and so on.

Not implemented: versions 4–8, sound, and the v3 split-window opcodes (they
are accepted and ignored, which is harmless for most v3 games but will affect
Seastalker's sonar pane and Border Zone's timed play).

Save files use a simple text format of this interpreter's own; they are not
Quetzal and won't interchange with Frotz or ZMPP.

## Tests

    luajit tools/test_coroutine.lua   # the VM under a coroutine, as the plugin drives it
    luajit tools/test_plugin.lua      # the plugin's control flow against stubbed KOReader
    ./tools/sync.sh                   # keep zmachine.koplugin/zm in step with zm/

`test_plugin.lua` stubs KOReader's widgets and drives the real interpreter, so
plugin logic can be checked without a device.

## Status

Verified against Hitchhiker's Guide to the Galaxy (release 59, serial 851108):
header checksum matches, the game boots, parses commands, tracks score and
turns, saves and restores, and plays through to its endings.
