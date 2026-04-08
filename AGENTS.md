# ksvisu

Kafka Streams Topology Visualizer written in C3 with raylib for GUI rendering.

## Build & Run

Requires the [C3 compiler](https://c3-lang.org/getting-started/prebuilt-binaries/) (`c3c`).

```sh
c3c build ksvisu     # compile
c3c run ksvisu       # compile and run (needs a .desc file arg)
./build/ksvisu <topology.desc>
./build/ksvisu <topology.desc> <kotlin-src-dir>   # with Kotlin source correlation
```

## Project Structure

```
src/
  main.c3           -- entry point, topology .desc parser, topology transforms, node correlation
  graph.c3          -- raylib GUI: graph layout (BFS layering, barycenter), drawing, camera
  kotlin_index.c3   -- Kotlin source scanner: indexes DSL calls to correlate with topology nodes
  gui_util.c3       -- small utility (clamp)
lib/
  raylib55.c3l      -- raylib v5.5 C3 library (pre-compiled for macOS/Linux/Windows/wasm)
resources/
  *.desc            -- sample Kafka Streams topology description files
  *.ttf             -- JetBrains Mono fonts for GUI
project.json        -- C3 project configuration
```

## Key Types

### src/main.c3

- `Kind` -- enum: `SOURCE`, `PROCESSOR`, `SINK`, `TOPIC` (synthetic cross-sub-topology bridge), `STORE` (synthetic state store node)
- `Node` -- name, kind, sub_topology, sub_topology_secondary (for TOPIC nodes bridging two sub-topologies), topics, stores, upstream/downstream lists, is_merged, is_join, source_refs (correlated Kotlin source locations), layout fields (layer, x, y, barycenter)
- `SourceRef` -- file (relative path), line (1-indexed), content (trimmed line text)
- `Topology` -- `HashMap{String, Node*}` of all parsed nodes + `Allocator`
- `KotlinIndex` -- `HashMap{String, SourceRefList}` mapping topology-relevant strings to source locations
- `NodeList` / `TopicNodeMap` -- aliases for `List{Node*}` and `HashMap{String, NodeList}`

### src/kotlin_index.c3

- `VarMap` -- `HashMap{String, String}` resolving Kotlin variable references (e.g., `Topics.dp` -> `teamdagpenger.utbetaling.v1`)
- `scan_kotlin_sources(dir)` -- two-pass scanner: collects Topic/Table declarations (pass 1), then indexes DSL calls like `consume()`, `produce()`, `.leftJoin()`, `.repartition()` (pass 2)
- `correlate_nodes()` (in main.c3) -- matches node names, topics, and stores against the index, stripping known prefixes (`consume-`, `ktable-`, `from-`) and suffixes (`-repartition-*`)

### src/graph.c3

- `State` -- GUI state: original + collapsed topology, source toggles, `visible_nodes` HashMap (computed via BFS from enabled SOURCEs), fonts, camera state, selected node, `highlighted_nodes` (transitive neighbors of selected node)
- `Toggle` -- `source_name` (SOURCE node name, "" for ALL button), `label` (ZString showing topic names), `button` (Rectangle), `enabled` (bool)
- `Fonts` -- regular, thin, bold (JetBrains Mono variants)

## GUI Architecture

- **Source toggles**: one button per SOURCE node, labeled with its Kafka topic(s). An ALL master toggle enables/disables all at once. Buttons are stacked vertically in the bottom-right corner.
- **Visibility**: `compute_visible_nodes()` does BFS downstream + upstream from each enabled SOURCE toggle. The union of all reachable nodes forms `visible_nodes`. A shared node stays visible if reachable from any enabled SOURCE.
- **Graph layout**: BFS longest-path layering from root SOURCE nodes (`graph()`), then barycenter heuristic for edge-crossing minimization (`calculate_positions()`). Layers are compacted and collapsed to remove gaps.
- **Node selection**: left-click a node to select it; BFS computes the transitive highlight set (all upstream ancestors + downstream descendants). Highlighted edges and nodes get a yellow glow.
- **Source panel**: when a selected node has correlated Kotlin source references, a panel in the top-left shows each file:line and the Kotlin code at that location.
- **Camera**: mouse wheel to zoom, left-click drag to pan.

## Kotlin Source Correlation

When a Kotlin source directory is provided as the second CLI argument, ksvisu scans all `.kt` files recursively and builds an index of strings that appear as topology node names, topic names, or store names. The scanner recognizes the custom Kafka wrapper library patterns:

- `Topic("name", ...)` -- topic name declarations
- `Table(Topics.X, ...)` -- table/store declarations (resolves default and explicit `stateStoreName`)
- `consume(Topics.X)` / `consume(Tables.X)` -- source node references
- `.produce(Topics.X)` -- sink node references
- `.leftJoin(..., "name")` -- named join operators
- `.repartition(Topics.X, N, "from-${Topics.X.name}")` -- named repartition operators
- `.merge(consume(Topics.X))` -- merge references
- `globalKTable(Tables.X)` -- global table references
- `Store(Tables.X)` -- store declarations

The scanner resolves `${Topics.X.name}` string templates by looking up the Topic variable's name from pass 1.

## Known Issues

- Font paths use relative paths (`resources/...`); the binary must be run from the project root directory.
- No tests exist yet (`test/` is empty).
- `LICENSE` file is empty.
- Kotlin source correlation only works with the custom `libs/kafka` wrapper library DSL patterns; raw Kafka Streams Java DSL calls are not recognized.
