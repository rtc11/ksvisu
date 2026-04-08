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

## Key Types

### src/main.c3

- `Kind` -- enum: `SOURCE`, `PROCESSOR`, `SINK`, `TOPIC` (synthetic cross-sub-topology bridge), `STORE` (synthetic state store node)
- `Node` -- name, kind, sub_topology, sub_topology_secondary (for TOPIC nodes bridging two sub-topologies), topics, stores, upstream/downstream lists, is_merged, is_join, layout fields (layer, x, y, barycenter)
- `Topology` -- `HashMap{String, Node*}` of all parsed nodes + `Allocator`
- `Options` -- CLI flags (show_all, diff, gui, paths)
- `NodeList` / `TopicNodeMap` -- aliases for `List{Node*}` and `HashMap{String, NodeList}`

### src/graph.c3

- `State` -- GUI state: original + collapsed topology, source toggles, `visible_nodes` HashMap (computed via BFS from enabled SOURCEs), fonts, camera state, selected node, `highlighted_nodes` (transitive neighbors of selected node)
- `Toggle` -- `source_name` (SOURCE node name, "" for ALL button), `label` (ZString showing topic names), `button` (Rectangle), `enabled` (bool)
- `Fonts` -- regular, thin, bold (JetBrains Mono variants)

## GUI Architecture

- **Source toggles**: one button per SOURCE node, labeled with its Kafka topic(s). An ALL master toggle enables/disables all at once. Buttons are stacked vertically in the bottom-right corner.
- **Visibility**: `compute_visible_nodes()` does BFS downstream + upstream from each enabled SOURCE toggle. The union of all reachable nodes forms `visible_nodes`. A shared node stays visible if reachable from any enabled SOURCE.
- **Graph layout**: BFS longest-path layering from root SOURCE nodes (`graph()`), then barycenter heuristic for edge-crossing minimization (`calculate_positions()`). Layers are compacted and collapsed to remove gaps.
- **Node selection**: left-click a node to select it; BFS computes the transitive highlight set (all upstream ancestors + downstream descendants). Highlighted edges and nodes get a yellow glow.
- **Camera**: mouse wheel to zoom, left-click drag to pan.

## Known Issues

- Font paths in `src/graph.c3:201-203` are hardcoded absolute paths; must be updated for other machines.
- No tests exist yet (`test/` is empty).
- `LICENSE` file is empty.
