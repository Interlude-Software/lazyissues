---
name: roundtrip
description: Run the headless JSON-fidelity roundtrip test that verifies issue.json files encode byte-identically. Use after touching the codec (json.lua), schema (config.lua), or store, or when asked to run the roundtrip/fidelity test. Optionally pass a data-root path to test real data instead of the bundled fixture.
---

Run the headless roundtrip codec test from the repo root. It decodes then re-encodes every `issue.json` and reports byte-identical vs diffs.

Against the bundled fixture (default):

```
nvim --headless --clean \
  -c "lua package.path='./lua/?.lua;./lua/?/init.lua;./?.lua;'..package.path" \
  -c "lua require('test.roundtrip').run()" -c "qa!"
```

Against a real data root — pass the absolute path as the argument to `run()`:

```
nvim --headless --clean \
  -c "lua package.path='./lua/?.lua;./lua/?/init.lua;./?.lua;'..package.path" \
  -c "lua require('test.roundtrip').run('$ARGUMENTS')" -c "qa!"
```

If `$ARGUMENTS` is empty, use the fixture form (no argument). Report the pass/diff output back to the user; any non-byte-identical file is a codec regression and must be fixed.
