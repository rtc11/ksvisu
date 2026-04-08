# ksvisu

Kafka Streams Topology Visualizer written in C3 with raylib for GUI rendering.

## Build & Run

Requires the [C3 compiler](https://c3-lang.org/getting-started/prebuilt-binaries/) (`c3c`).

```sh
c3c build ksvisu     # compile
c3c run ksvisu       # compile and run (needs a .desc file arg)
./build/ksvisu <topology.desc> [-a] [-d <other.desc>] [-g]
```

Flags: `-a` show all nodes, `-d` diff two topologies, `-g` open GUI window.

## Project Structure

```
src/
  main.c3       -- entry point, CLI parsing, topology .desc parser, text/diff output
  graph.c3      -- raylib GUI: graph layout (BFS layering, barycenter), drawing, camera
  gui_util.c3   -- small utility (clamp)
  color.c3      -- ANSI terminal color helpers
lib/
  raylib55.c3l  -- raylib v5.5 C3 library (pre-compiled for macOS/Linux/Windows/wasm)
resources/
  *.desc        -- sample Kafka Streams topology description files
  *.ttf         -- JetBrains Mono fonts for GUI
project.json    -- C3 project configuration
```

## Key Types (src/main.c3)

- `Topology` -- `HashMap{String, Node*}` of all parsed nodes
- `Node` -- name, kind (SOURCE/PROCESSOR/SINK), topics, stores, upstream/downstream, layout fields
- `Options` -- CLI flags
- `State` (src/graph.c3) -- GUI state: topology, toggles, fonts, camera, selected node

## Known Issues

- Font paths in `src/graph.c3:76-78` are hardcoded absolute paths; must be updated for other machines.
- No tests exist yet (`test/` is empty).
- `LICENSE` file is empty.
