# g4recomp

g4recomp is a LÖVE application that turns a legally-owned Nintendo DS
Pokémon HeartGold or SoulSilver ROM into a private, derived game data cache
and runs the game from that cache.

This project is not an emulator and does not ship copyrighted ROM data,
dialogue, graphics, models, or audio. You must provide your own compatible ROM;
the importer recognizes only the supported canonical US dumps and keeps
ROM-derived data in LÖVE's per-user save directory.

## Requirements

- [LÖVE 11.5](https://love2d.org/)

Contributors also need [StyLua](https://github.com/JohnnyMorganz/StyLua) and
[LuaLS](https://github.com/LuaLS/lua-language-server) on `PATH`. The normal
development commands ensure the repository's committed Git hooks are configured
before they run; setup is local and does not install project dependencies.

## Quick start

Run commands from the repository root:

```sh
scripts/run.sh
scripts/buildcache.sh [ROM]
scripts/test.sh [--rom-source ROM]
scripts/lint.sh          # format Lua, then run fast static/policy checks
scripts/lint.sh --check  # check without modifying files
```

`buildcache.sh` accepts a compatible `.nds` or `.zip` source when a raw dump is
not already available. `test.sh` runs every available test layer; the optional
`--rom-source` performs an isolated source-backed run. `lint.sh` runs its
formatting/policy checks alongside a reduced-workspace LuaLS pass (tests
excluded) in the background, so its wall time tracks the slower of the two
rather than their sum; that pass is a fast local signal, not full coverage.
Pre-commit runs the non-mutating lint check only; CI runs both lint and the
full workspace typecheck.

See [the architecture principles](docs/architecture.md) for ownership,
dependency direction, and data-lifecycle guidance.
