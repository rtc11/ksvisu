# Skill: C3 + Raylib + Kafka Streams Topology Descriptions

Domain reference for working with the C3 programming language, raylib graphics library (via C3 bindings), and Kafka Streams topology description files.

---

## 1. C3 Programming Language

C3 is a systems programming language that evolves C while retaining familiarity. It has full C ABI compatibility, a module system, zero-overhead error handling, and an LLVM backend.

- Docs: https://c3-lang.org/getting-started/
- Repo: https://github.com/c3lang/c3c

### 1.1 Naming Conventions (Enforced by Compiler)

```
MyType          // User-defined types: starts uppercase, contains at least one lowercase
my_variable     // Variables, functions, struct members: starts lowercase
MY_CONSTANT     // Constants and enum values: all uppercase
my_module       // Module names: lowercase with :: separators
```

### 1.2 Modules and Imports

Every `.c3` file starts with a `module` declaration. Imports are recursive (importing a parent imports children).

```c3
module myapp;

import std::io;
import std::collections::map;
```

- Types from other modules don't need a prefix: `HashMap` works if imported.
- Functions from other modules need a prefix: `io::printfn(...)`.
- Multiple files can share the same module name -- they are merged.

### 1.3 Basic Types

| C3 Type   | Size        | Notes                                 |
|-----------|-------------|---------------------------------------|
| `bool`    | 1 byte      |                                       |
| `char`    | 1 byte      | Unsigned                              |
| `short`   | 16 bits     | Signed                                |
| `ushort`  | 16 bits     | Unsigned                              |
| `int`     | 32 bits     | Signed (always 32-bit, unlike C)      |
| `uint`    | 32 bits     | Unsigned                              |
| `long`    | 64 bits     | Signed                                |
| `ulong`   | 64 bits     | Unsigned                              |
| `int128`  | 128 bits    | Signed                                |
| `float`   | 32 bits     | IEEE 754                              |
| `double`  | 64 bits     | IEEE 754                              |
| `usz`     | ptr-sized   | Equivalent to C `size_t`              |
| `isz`     | ptr-sized   | Equivalent to C `ptrdiff_t`           |
| `iptr`    | ptr-sized   | Equivalent to C `intptr_t`            |
| `uptr`    | ptr-sized   | Equivalent to C `uintptr_t`           |
| `String`  | slice       | `char[]` slice (pointer + length)     |
| `ZString` | pointer     | Null-terminated C string (`char*`)    |

### 1.4 Variables

Variables are **zero-initialized by default**. Use `@noinit` to skip initialization.

```c3
int a;              // Initialized to 0
int b = 42;         // Explicit value
int c @noinit;      // Uninitialized (opt-in)
```

### 1.5 Functions

Functions use the `fn` keyword. Methods are functions namespaced to a type.

```c3
fn int add(int a, int b) {
    return a + b;
}

// Method on a struct (first param is the receiver)
fn bool Node.is_stateful(&self) => self.stores.len() > 0;

// Short expression body with =>
fn float clamp(float value, float min, float max) {
    return math::min(math::max(value, min), max);
}
```

### 1.6 Structs

```c3
struct Node {
    int sub_topology;
    String name;
    Kind kind;
    List{String} topics;
    List{String} stores;
    // GUI layout fields
    int layer;
    float x;
    float y;
}
```

- No semicolon after the closing brace.
- Struct literals: `{ .field = value, .other = value }` or positional `{ val1, val2 }`.
- Heap-allocate with `allocator::new(alloc, Type, { initializer })`.

### 1.7 Enums

```c3
enum Kind {
    SOURCE,
    PROCESSOR,
    SINK
}
```

- Enums are always namespaced but can be used without prefix in switch cases.
- Enums support `.values`, `.len`, `.names` for reflection.
- Underlying type defaults to `int`, can be changed: `enum Foo : uint { ... }`.

### 1.8 Error Handling (Optionals)

C3 uses Optionals instead of exceptions or error codes. A function that can fail returns `Type?` (an Optional).

```c3
// Define fault types
faultdef ILLEGAL_ARG, NOT_FOUND;

// Function returning an Optional
fn int? divide(int a, int b) {
    if (b == 0) return ILLEGAL_ARG?;
    return a / b;
}

// Rethrow with ! (propagates the fault up)
fn void? caller() {
    int result = divide(10, 2)!;  // Unwraps or returns fault
}

// Force unwrap with !! (panics on fault -- use sparingly)
int result = divide(10, 2)!!;

// Check with if (catch)
if (catch err = divide(10, 0)) {
    io::printfn("Error: %s", err);
}

// Check with if (try)
if (try result = divide(10, 2)) {
    io::printfn("Result: %d", result);
}
```

### 1.9 Memory Management

C3 has manual memory management with allocator support.

**Stack allocation** -- default for local variables.

**Heap allocation:**
```c3
int* p = mem::new(int, 42);       // Zero-init, set to 42
Foo* f = mem::new(Foo, { .x = 1 });
free(p);
```

**Temporary allocator (`tmem`)** -- arena-style, freed in bulk with `@pool()`:
```c3
fn void main(String[] args) {
    @pool() {
        // Everything allocated with tmem inside here is freed at scope exit
        String[] lines = ((String)file::load(tmem, "file.txt")!!).tsplit("\n");
        // ... use lines ...
    };  // All tmem allocations freed here
}
```

**Allocator-aware types:**
```c3
Topology topo = { .alloc = tmem };              // Stores the allocator
Node* node = allocator::new(self.alloc, Node, { .name = "foo" });
```

**Key functions:**
- `tmalloc(size)` -- allocate from temp allocator
- `allocator::new(alloc, Type, initializer)` -- typed allocation
- `string::tformat(fmt, args...)` -- format string using temp allocator
- `string::tformat_zstr(fmt, args...)` -- format to ZString using temp allocator
- `.tsplit(sep)` -- split string using temp allocator
- `.tvalues()` -- get values array from HashMap using temp allocator

### 1.10 Collections

**List (dynamic array):**
```c3
List{String} items;
items.push("hello");
items.push("world");
String first = items[0];
usz count = items.len();
items.tinit();              // Initialize with temp allocator
```

**HashMap:**
```c3
HashMap{String, Node*} nodes;
nodes.@get_or_set(key, value);  // Insert if not present
Node* n = nodes.get(key);       // Lookup (returns Optional)
Node*? n = nodes[key];          // Subscript (returns Optional)
bool exists = nodes.has_key(key);
nodes.@each(; String key, Node* val) { ... };  // Iterate
Node*[] all = nodes.tvalues();  // Get all values as array
```

**DString (dynamic string):**
```c3
DString out;
out.append("hello");
String view = out.str_view();
```

### 1.11 Control Flow

**Switch** -- implicit break, use `nextcase` to fallthrough:
```c3
switch (node.kind) {
    case SOURCE:  color = GREEN;
    case PROCESSOR: color = self.is_stateful() ? RED : PURPLE;
    case SINK:    color = BLUE;
}

// Switch on bool expressions (no argument)
switch {
    case line.contains("Source: "): ...
    case line.contains("Processor: "): ...
    case line.contains("Sink: "): ...
}
```

**Foreach:**
```c3
foreach (node : nodes) { ... }
foreach (i, node : nodes) { ... }   // With index
foreach (&node : nodes) { ... }     // By reference
```

**For loop** -- same as C99:
```c3
for (int i = 0; i < 10; i++) { ... }
```

**While:**
```c3
while (offset < input.len) { ... }
```

### 1.12 Aliases

```c3
alias Nodes = List{Node*};
alias NodesByLayer = List{Nodes};
alias Color = int[3];
```

### 1.13 String Operations

```c3
String s = "hello world";
bool has = s.contains("world");
String[] parts = s.tsplit(" ");      // Split with temp allocator
String trimmed = s.trim();
usz pos = s.index_of_char('[')!!;    // Returns Optional
int? num = s.to_int();               // Parse to int (Optional)
ZString zs = s.zstr_tcopy();         // Convert to null-terminated (temp)
```

### 1.14 Compile-Time Features

```c3
// Compile-time if
$if $n <= 1:
    return $n;
$else
    return fib($n - 1) + fib($n - 2);
$endif

// Compile-time foreach over type members
$foreach $field : $Type.membersof:
    io::printfn("Field: %s", $field.nameof);
$endforeach
```

### 1.15 Constants

```c3
const int SCREEN_WIDTH = 1600;
const float NODE_RADIUS = 50;
const rl::Color BG = { 20, 28, 33, 255 };
```

### 1.16 Build System (project.json)

```json
{
  "langrev": "1",
  "warnings": ["no-unused"],
  "dependency-search-paths": ["lib"],
  "dependencies": ["raylib55"],
  "authors": ["rtc11"],
  "version": "0.1.0",
  "sources": ["src/**"],
  "test-sources": ["test/**"],
  "build-dir": "build",
  "output": "build",
  "targets": {
    "ksvisu": {
      "type": "executable",
      "macos-min-version": "15.0",
      "macos-sdk-version": "15.0"
    }
  },
  "cpu": "generic",
  "opt": "O0"
}
```

**Build commands:**
```sh
c3c build <target>       # Compile
c3c run <target>         # Compile and run
c3c test                 # Run tests (@test attributed functions)
c3c clean                # Remove build artifacts
c3c init <name>          # Create new project
```

**C3 libraries (`.c3l`):** Pre-compiled library packages placed in the `lib/` directory and listed in `"dependencies"`. They contain C3 interface files and pre-compiled static libraries for each platform.

### 1.17 Tests

```c3
fn void test_something() @test {
    assert(1 + 1 == 2, "math works");
}
```

Tests are placed in `test/` (or wherever `"test-sources"` points) and run with `c3c test`.

### 1.18 Sorting

```c3
import std::sort;

// Sort a list with default comparison
quicksort(&my_list);

// Sort with custom comparator
quicksort(&my_list, &my_comparator);

fn int my_comparator(Node* a, Node* b) {
    if (a.value < b.value) return -1;
    if (a.value > b.value) return 1;
    return 0;
}
```

---

## 2. Raylib (via C3 Bindings)

Raylib is a C library for game/graphics programming. In C3, it is imported as `raylib5` and functions are called through the `rl::` namespace.

- Raylib docs: https://www.raylib.com/cheatsheet/cheatsheet.html
- C3 binding: `lib/raylib55.c3l`

### 2.1 Import and Namespacing

```c3
import raylib5;

// All raylib functions are accessed via rl:: prefix
rl::initWindow(1600, 1200, "My App");
```

### 2.2 Window Lifecycle

```c3
rl::setConfigFlags(MSAA_4X_HINT);                    // Before init
rl::initWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "Title");
rl::setMouseCursor(CROSSHAIR);

while (!rl::windowShouldClose()) {
    // ... update & draw ...
}

rl::closeWindow();
```

### 2.3 Drawing Cycle

Every frame follows this pattern:

```c3
rl::beginDrawing();
rl::clearBackground(BG);

// Draw HUD / screen-space elements
rl::drawTextEx(font, "text", {10f, 10f}, 20, 4f, rl::WHITE);

// Draw world-space elements with camera
rl::beginMode2D(camera);
// ... draw nodes, edges, etc. ...
rl::endMode2D();

rl::endDrawing();
```

### 2.4 2D Camera

```c3
Camera2D camera = {
    .offset = { SCREEN_WIDTH / 2f, SCREEN_HEIGHT / 2f },  // Screen center
    .target = { world_x, world_y },                         // World point at center
    .zoom = 1f,
};

rl::beginMode2D(camera);
// Everything drawn here is transformed by the camera
rl::endMode2D();

// Convert between screen and world coordinates
Vector2 world_pos = rl::getScreenToWorld2D(screen_pos, camera);
```

**Zoom (mouse wheel):**
```c3
float wheel = rl::getMouseWheelMove();
if (wheel != 0f) {
    Vector2 mouse = rl::getMousePosition();
    Vector2 world_before = rl::getScreenToWorld2D(mouse, camera);
    camera.zoom += wheel * ZOOM_SPEED * camera.zoom;
    camera.zoom = clamp(camera.zoom, MIN_ZOOM, MAX_ZOOM);
    Vector2 world_after = rl::getScreenToWorld2D(mouse, camera);
    camera.target.x += (world_before.x - world_after.x);
    camera.target.y += (world_before.y - world_after.y);
}
```

**Pan (mouse drag):**
```c3
if (rl::isMouseButtonPressed(LEFT)) {
    is_panning = true;
    last_pos = rl::getScreenToWorld2D(rl::getMousePosition(), camera);
}
if (rl::isMouseButtonReleased(LEFT)) {
    is_panning = false;
}
if (is_panning) {
    Vector2 current = rl::getScreenToWorld2D(rl::getMousePosition(), camera);
    camera.target.x -= (current.x - last_pos.x);
    camera.target.y -= (current.y - last_pos.y);
}
```

### 2.5 Shape Drawing

```c3
// Circle
rl::drawCircle((int)x, (int)y, radius, color);
rl::drawCircleV(center_vec2, radius, color);
rl::drawCircleLinesV(center_vec2, radius, color);  // Outline only

// Rectangle
rl::drawRectangleRec(rect, color);                  // Filled
rl::drawRectangleLinesEx(rect, thickness, color);   // Outline

// Line
rl::drawLineEx(start_vec2, end_vec2, thickness, color);

// Triangle (vertices must be counter-clockwise)
rl::drawTriangle(v1, v2, v3, color);
```

### 2.6 Text Rendering

```c3
// Load font from file
Font font = rl::loadFont("path/to/font.ttf");

// Draw text with font
rl::drawTextEx(font, zstring, position_vec2, font_size, spacing, color);

// Measure text width
int width = rl::measureText(zstring, font_size);
Vector2 size = rl::measureTextEx(font, zstring, font_size, spacing);
```

Note: `drawTextEx` requires a `ZString` (null-terminated). Convert with `.zstr_tcopy()`.

### 2.7 Input Handling

```c3
// Mouse
Vector2 pos = rl::getMousePosition();
bool pressed = rl::isMouseButtonPressed(LEFT);
bool released = rl::isMouseButtonReleased(LEFT);
float wheel = rl::getMouseWheelMove();

// Keyboard
bool enter = rl::isKeyPressed(rl::KEY_ENTER);

// Collision detection
bool hit_circle = rl::checkCollisionPointCircle(point, center, radius);
bool hit_rect = rl::checkCollisionPointRec(point, rect);
```

### 2.8 Vector2 Math

```c3
Vector2 diff = rl::vector2Subtract(a, b);
float len = rl::vector2Length(vec);
Vector2 scaled = rl::vector2Scale(vec, factor);
Vector2 sum = rl::vector2Add(a, b);
Vector2 lerped = rl::vector2Lerp(start, end, t);  // t in [0, 1]
```

### 2.9 Colors

```c3
// rl::Color is { r, g, b, a } where each is a byte (0-255)
const rl::Color BG = { 20, 28, 33, 255 };

// Built-in colors
rl::WHITE, rl::BLACK, rl::DARKGRAY  // etc.
```

### 2.10 Common Types

```c3
struct Vector2 { float x; float y; }
struct Rectangle { float x; float y; float width; float height; }
struct Camera2D { Vector2 offset; Vector2 target; float rotation; float zoom; }
struct Font { ... }  // Opaque, loaded with rl::loadFont
```

---

## 3. Kafka Streams Topology Description Files (.desc)

A `.desc` file contains the text output of `TopologyDescription.toString()` from the Kafka Streams API. It describes the directed acyclic graph (DAG) of a Kafka Streams application's processing topology.

### 3.1 Overall Structure

```
Topologies:
   Sub-topology: 0
    Source: <name> (topics: [<topic1>, <topic2>])
      --> <downstream1>, <downstream2>
    Processor: <name> (stores: [<store1>, <store2>])
      --> <downstream>
      <-- <upstream>
    Sink: <name> (topic: <topic>)
      <-- <upstream>

  Sub-topology: 1
    ...
```

Key structural rules:
- The file begins with `Topologies:`.
- Each sub-topology is introduced by `Sub-topology: <id>` (integer id, starting from 0).
- Nodes are indented under their sub-topology.
- Each node has a type line, then optional `-->` (downstream) and `<--` (upstream) lines.

### 3.2 Node Types

**Source** -- reads from one or more Kafka topics:
```
Source: consume-helved.simuleringer.v1 (topics: [helved.simuleringer.v1])
  --> KSTREAM-PROCESSOR-0000000001
```
- Format: `Source: <name> (topics: [<comma-separated topics>])`
- Sources have no upstream (`<--` line).
- Sources are the entry points of a sub-topology.

**Processor** -- transforms or processes records:
```
Processor: KSTREAM-FILTER-0000000002 (stores: [])
  --> KSTREAM-MAPVALUES-0000000003
  <-- KSTREAM-PROCESSOR-0000000001
```
- Format: `Processor: <name> (stores: [<comma-separated store names>])`
- `stores: []` means stateless; `stores: [my-store]` means stateful.
- Stateful processors are significant for operational monitoring (they maintain local state).

**Sink** -- writes to a single Kafka topic:
```
Sink: KSTREAM-SINK-0000000015 (topic: helved.dryrun-aap.v1)
  <-- KSTREAM-PROCESSOR-0000000014
```
- Format: `Sink: <name> (topic: <single-topic>)`
- Note: sinks use `topic:` (singular) while sources use `topics:` (plural with brackets).
- Sinks have no downstream (`-->` line), or `-->  none`.

### 3.3 Connections

```
  --> KSTREAM-BRANCH-00000000041, KSTREAM-BRANCH-00000000040
  <-- KSTREAM-MAPVALUES-0000000003
```

- `-->` lists downstream nodes (comma-separated).
- `<--` lists upstream nodes (comma-separated).
- `none` means no connections in that direction.
- Connections are always within the same sub-topology, unless linked via repartition topics (a sink in one sub-topology writes to a topic that a source in another sub-topology reads).

### 3.4 Sub-Topologies

- Each sub-topology is an independent partition-processing unit.
- Sub-topologies are connected implicitly through Kafka topics (one sub-topology sinks to a topic that another sources from).
- Repartition topics (e.g., `ktable-helved.kvittering.v1-repartition`) are internal topics created by Kafka Streams for re-keying data between sub-topologies.
- A special annotation `Sub-topology: 0 for global store (will not generate tasks)` can appear for global store sub-topologies -- the id portion won't parse as a plain integer.

### 3.5 Common Node Name Patterns

Kafka Streams generates auto-named nodes following patterns:

| Pattern                              | Meaning                              |
|--------------------------------------|--------------------------------------|
| `KSTREAM-SOURCE-*`                   | KStream source                       |
| `KSTREAM-SINK-*`                     | KStream sink                         |
| `KSTREAM-PROCESSOR-*`               | Generic processor                    |
| `KSTREAM-FILTER-*`                   | Filter operation                     |
| `KSTREAM-MAPVALUES-*`               | MapValues transform                  |
| `KSTREAM-BRANCH-*`                   | Branch/split                         |
| `KSTREAM-MAP-*`                      | Map (key+value) transform            |
| `KSTREAM-FOREACH-*`                  | ForEach terminal operation           |
| `KTABLE-JOINTHIS-*` / `JOINOTHER-*` | KTable join (left/right side)        |
| `KTABLE-MERGE-*`                     | Merge after join                     |
| `KTABLE-TOSTREAM-*`                  | KTable to KStream conversion         |
| `*-repartition-filter`               | Pre-repartition filter               |
| `*-repartition-sink`                 | Repartition sink                     |
| `*-repartition-source`               | Repartition source                   |
| `consume-<topic>`                    | Named source consuming a topic       |
| `dedup-<name>`                       | Custom deduplication processor        |
| `fk-<name>-materialize`             | Foreign key join materialization     |

User-defined processor names (like `consume-helved.simuleringer.v1` or `dedup-kvittering`) break the auto-generated naming pattern and provide semantic meaning.

### 3.6 State Stores

State stores appear in the `(stores: [...])` of Processor nodes:
```
Processor: dedup-kvittering (stores: [dedup-kvittering])
Processor: ktable-helved.kvittering.v1 (stores: [helved.kvittering.v1-state-store])
```

- A processor may reference stores it does not own (e.g., in join operations, both sides of a join reference each other's stores).
- Stateful processors are operationally significant: they require local disk, have changelog topics, and affect rebalancing behavior.

### 3.7 Parsing Considerations

When writing a parser for `.desc` files:

1. **Indentation matters** -- sub-topology headers and node definitions are at different indent levels.
2. **Node definition starts** -- look for `Source: `, `Processor: `, or `Sink: ` prefixes.
3. **Connection lines** -- `-->` and `<--` are always indented under their parent node.
4. **Square brackets for lists** -- topics in sources and stores in processors use `[...]`. Sinks use `(topic: <name>)` without brackets.
5. **Empty lists** -- `stores: []` and `topics: []` are common; handle the empty-bracket case.
6. **Comma separation** -- both topic lists and connection lists are comma-separated.
7. **The `none` sentinel** -- `-->  none` means no downstream connections.
8. **Blank lines** -- separate sub-topologies; a blank line or a new `Sub-topology:` header signals the end of the current sub-topology.
9. **Global store sub-topologies** -- may have non-integer annotations after the id number.

### 3.8 Example: Minimal Topology

```
Topologies:
   Sub-topology: 0
    Source: my-source (topics: [input-topic])
      --> my-processor
    Processor: my-processor (stores: [my-store])
      --> my-sink
      <-- my-source
    Sink: my-sink (topic: output-topic)
      <-- my-processor
```

This describes a simple pipeline: read from `input-topic`, process with state store `my-store`, write to `output-topic`.
