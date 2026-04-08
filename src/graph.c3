module ksvisu;

import std::io;
import std::math;
import std::collections::list;
import std::collections::map;
import std::collections::pair;
import std::sort;
import raylib5;

const int SCREEN_WIDTH = 1600;
const int SCREEN_HEIGHT = 1200;
const float NODE_RADIUS = 50;
const float NODE_PADDING = 50;
const float MARGIN = NODE_PADDING;
const float NODE_VERTICAL_STEP = (2 * NODE_RADIUS) + NODE_PADDING;
const int LONG_EDGE_LAYER_THRESHOLD = 2;   // edges spanning more layers than this get curved
const float BEZIER_CURVE_OFFSET = 150f;    // base perpendicular offset for bezier control point
const float MAX_BEZIER_OFFSET = 600f;      // cap so extremely long edges don't bow too far

const rl::Color BG = { 20, 28, 33, 255};
const rl::Color BODY = { 13, 18, 20, 255};
const rl::Color GREEN = { 37, 135, 43, 255};
const rl::Color RED = { 200, 50, 50, 255};
const rl::Color PURPLE = { 181, 33, 127, 255};
const rl::Color BLUE = { 50, 100, 200, 255};
const rl::Color GOLD = { 218, 165, 35, 255};
const rl::Color HIGHLIGHT_YELLOW = { 255, 255, 0, 255};
const rl::Color HIGHLIGHT_DIM = { 255, 255, 0, 100};   // softer glow for transitive neighbors
const rl::Color SILVER = {192, 192, 192, 255};
const rl::Color TEAL = { 69, 200, 220, 255};
const rl::Color ORANGE = { 255, 165, 0, 255};
const rl::Color JOIN_BG = { 255, 165, 0, 40};  // translucent orange for join group boxes

alias Nodes = List{Node*};
alias NodesByLayer = List{Nodes};

struct Fonts {
    Font regular;
    Font thin;
    Font bold;
}

struct State
{
    Topology topo;
    Topology collapsed_topo;     // always-active merged topology (sinks/sources collapsed by topic)
    List{Toggle*} toggles;
    HashMap{String, bool} visible_nodes; // computed set of nodes reachable from enabled SOURCEs
    Fonts fonts;
    usz max_layer;           // max layers in the (enabled) sub-topologies
    bool is_panning;         // when left mouse is pressed and screen is dragged
    Vector2 last_mouse_pos_world; 
    bool recalculate_layout; // when to recalculate graph and calculate_positions
    float max_node_width;    // max horizontal space required by a node's label
    Node* selected_node;
    HashMap{String, bool} highlighted_nodes; // transitive upstream + downstream of selected node
}


struct Toggle
{
    ZString label;
    String source_name;  // SOURCE node name ("" for ALL button)
    Rectangle button;
    bool enabled;
}

fn bool Toggle.less(&self, Toggle* other) => self.label < other.label; // used in quicksort

// Check if a node is visible based on the computed visible_nodes set.
// A node is visible if it was reached by BFS from any enabled SOURCE toggle.
fn bool State.is_node_visible(&self, Node* node) {
    return self.visible_nodes.has_key(node.name);
}

// Compute the transitive set of highlighted nodes (all upstream ancestors
// and all downstream descendants) reachable from the currently selected node.
fn void State.compute_highlighted_nodes(&self) {
    self.highlighted_nodes.clear();
    if (self.selected_node == null) return;

    Topology* topo = self.active_topo();
    self.highlighted_nodes.set(self.selected_node.name, true);

    // BFS downstream (descendants)
    List{String} queue;
    queue.tinit();
    foreach (ds : self.selected_node.downstream) {
        queue.push(ds);
    }
    while (queue.len() > 0) {
        String name = queue.pop()!!;
        if (self.highlighted_nodes.has_key(name)) continue;
        self.highlighted_nodes.set(name, true);
        Node*? node = topo.nodes.get(name);
        if (catch node) continue;
        foreach (ds : node.downstream) {
            if (!self.highlighted_nodes.has_key(ds)) {
                queue.push(ds);
            }
        }
    }

    // BFS upstream (ancestors)
    foreach (us : self.selected_node.upstream) {
        queue.push(us);
    }
    while (queue.len() > 0) {
        String name = queue.pop()!!;
        if (self.highlighted_nodes.has_key(name)) continue;
        self.highlighted_nodes.set(name, true);
        Node*? node = topo.nodes.get(name);
        if (catch node) continue;
        foreach (us : node.upstream) {
            if (!self.highlighted_nodes.has_key(us)) {
                queue.push(us);
            }
        }
    }
}

// Compute which nodes are visible by BFS from each enabled SOURCE toggle.
// A node is visible if it is reachable (downstream or upstream) from any
// enabled SOURCE node. This replaces the old sub-topology-based hiding.
fn void State.compute_visible_nodes(&self) {
    Topology* topo = self.active_topo();
    self.visible_nodes.clear();

    // For each enabled SOURCE toggle, BFS both downstream and upstream
    foreach (toggle : self.toggles) {
        if (toggle.source_name.len == 0) continue; // skip ALL button
        if (!toggle.enabled) continue;

        Node*? source_node = topo.nodes.get(toggle.source_name);
        if (catch source_node) continue;

        // BFS downstream from this SOURCE
        List{String} queue;
        queue.tinit();
        self.visible_nodes.set(source_node.name, true);
        foreach (ds : source_node.downstream) {
            queue.push(ds);
        }
        while (queue.len() > 0) {
            String name = queue.pop()!!;
            if (self.visible_nodes.has_key(name)) continue;
            self.visible_nodes.set(name, true);
            Node*? node = topo.nodes.get(name);
            if (catch node) continue;
            foreach (ds : node.downstream) {
                if (!self.visible_nodes.has_key(ds)) {
                    queue.push(ds);
                }
            }
        }

        // BFS upstream from this SOURCE
        foreach (us : source_node.upstream) {
            queue.push(us);
        }
        while (queue.len() > 0) {
            String name = queue.pop()!!;
            if (self.visible_nodes.has_key(name)) continue;
            self.visible_nodes.set(name, true);
            Node*? node = topo.nodes.get(name);
            if (catch node) continue;
            foreach (us : node.upstream) {
                if (!self.visible_nodes.has_key(us)) {
                    queue.push(us);
                }
            }
        }
    }
}

// Return the active topology (always the collapsed/merged version).
fn Topology* State.active_topo(&self) {
    return &self.collapsed_topo;
}

fn bool State.is_highlighted(&self, Node* node) {
    return self.highlighted_nodes.has_key(node.name);
}

fn void visualize(Topology topo)
{
    rl::setConfigFlags(MSAA_4X_HINT);
    rl::initWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "Kafka Streams Topology Visualizer");
    rl::setMouseCursor(CROSSHAIR);

    const float DRAW_WIDTH = SCREEN_WIDTH - (2f * MARGIN);
    const float DRAW_HEIGHT = SCREEN_HEIGHT - (2f * MARGIN);
    Camera2D camera = {
        .offset = { SCREEN_WIDTH / 2f, SCREEN_HEIGHT / 2f },
        .target = { MARGIN + DRAW_WIDTH / 2f, MARGIN + DRAW_HEIGHT / 2f },
        .zoom = 1f,
    };

    Fonts fonts = { 
        .regular = rl::loadFont("/Users/Robin.Tordly/code/c3/ksvisu/resources/JetBrainsMono-Regular.ttf"),
        .thin = rl::loadFont("/Users/Robin.Tordly/code/c3/ksvisu/resources/JetBrainsMonoNL-Thin.ttf"),
        .bold = rl::loadFont("/Users/Robin.Tordly/code/c3/ksvisu/resources/JetBrainsMono-Bold.ttf"),
    };

    State state = { 
        .topo = topo,
        .fonts = fonts, 
        .recalculate_layout = true,
    };

    state.setup_source_buttons(topo);

    while (!rl::windowShouldClose()) {
        if (rl::isKeyPressed(rl::KEY_ENTER)) break;

        camera.mouse_zoom();
        camera.mouse_panning(&state);

        camera.handle_input(&state);

        if (state.recalculate_layout) {
            // Restore edges from previous collapse before rebuilding
            if (state.collapsed_topo.nodes.count > 0) {
                state.topo.restore_edges(&state.collapsed_topo);
            }
            state.collapsed_topo = state.topo.build_collapsed();
            state.compute_visible_nodes();
            graph(&state);
            calculate_positions(&state);
            state.recalculate_layout = false;
        }

        rl::beginDrawing();
        rl::clearBackground(BG);
        rl::drawRectangleRec({MARGIN, MARGIN, SCREEN_WIDTH-(2*MARGIN), SCREEN_HEIGHT-(2*MARGIN)}, BODY);

        rl::beginMode2D(camera);
        draw_subtopology(&state);
        rl::endMode2D();

        rl::drawTextEx(state.fonts.regular, string::tformat_zstr("Zoom: %.2f", camera.zoom), {10f, 10f}, 20, 4f, rl::WHITE);

        draw_topology_toggles(&state);

        rl::endDrawing();
    }
    rl::closeWindow();
}

fn void draw_subtopology(State* state)
{
    Topology* topo = state.active_topo();

    // Draw join-group bounding boxes (behind everything)
    draw_join_groups(state);

    // Draw edges
    foreach (node: topo.nodes.tvalues()) {
        if (!state.is_node_visible(node)) continue;

        foreach(downstream_name: node.downstream) {
            Node*? downstream = topo.nodes[downstream_name];
            if (catch downstream) continue;

            if (state.is_node_visible(downstream)) {
                node.connect(*downstream, state);
            }
        }
    };

    // Draw nodes
    foreach (node: topo.nodes.tvalues()) {
        if (state.is_node_visible(node)) {
            node.draw(state);
        }
    }
}

// Draw translucent bounding boxes behind clusters of join-related nodes.
// A join group = all join nodes (is_join==true) that share a common store via
// their STORE node connections. We group by collecting each STORE node's upstream
// processors that have is_join, then draw a box around the group + the store node.
fn void draw_join_groups(State* state)
{
    Topology* topo = state.active_topo();
    const float PAD = 20f;

    // Find STORE nodes that connect to join processors
    foreach (node: topo.nodes.tvalues()) {
        if (node.kind != STORE) continue;
        if (!state.is_node_visible(node)) continue;

        // Collect all visible join processors connected to this store
        float min_x = node.x;
        float max_x = node.x;
        float min_y = node.y;
        float max_y = node.y;
        usz join_count = 0;

        foreach (us_name : node.upstream) {
            Node*? proc = topo.nodes.get(us_name);
            if (catch proc) continue;
            if (!state.is_node_visible(proc)) continue;
            if (!proc.is_join) continue;
            join_count++;
            if (proc.x - NODE_RADIUS < min_x) min_x = proc.x - NODE_RADIUS;
            if (proc.x + NODE_RADIUS > max_x) max_x = proc.x + NODE_RADIUS;
            if (proc.y - NODE_RADIUS < min_y) min_y = proc.y - NODE_RADIUS;
            if (proc.y + NODE_RADIUS > max_y) max_y = proc.y + NODE_RADIUS;
        }

        if (join_count < 1) continue;

        // Expand bounds to include the store node rectangle
        float store_left = node.x - STORE_RECT_W / 2f;
        float store_right = node.x + STORE_RECT_W / 2f;
        float store_top = node.y - STORE_RECT_H / 2f;
        float store_bottom = node.y + STORE_RECT_H / 2f;
        if (store_left < min_x) min_x = store_left;
        if (store_right > max_x) max_x = store_right;
        if (store_top < min_y) min_y = store_top;
        if (store_bottom > max_y) max_y = store_bottom;

        // Draw translucent bounding box with padding
        Rectangle box = {
            min_x - PAD,
            min_y - PAD,
            (max_x - min_x) + 2f * PAD,
            (max_y - min_y) + 2f * PAD,
        };
        rl::drawRectangleRounded(box, 0.1f, 4, JOIN_BG);
        rl::drawRectangleRoundedLinesEx(box, 0.1f, 4, 1f, ORANGE);
    }
}

fn void State.setup_source_buttons(&self, Topology topo)
{
    // Collect one toggle per SOURCE node, labeled with its topic(s)
    foreach(node: topo.nodes.tvalues()) {
        if (node.kind != SOURCE) continue;

        bool already_exists;
        foreach(existing_toggle: self.toggles) {
            if (existing_toggle.source_name == node.name) {
                already_exists = true;
                break;
            }
        }
        if (already_exists) continue;

        // Build label from the SOURCE's topics (e.g. "topicA, topicB")
        DString label_buf;
        label_buf.tinit();
        foreach(i, topic: node.topics) {
            if (i > 0) label_buf.append(", ");
            label_buf.append(topic);
        }
        // Fallback to node name if no topics
        ZString label;
        if (label_buf.len() > 0) {
            label = label_buf.str_view().zstr_tcopy();
        } else {
            label = node.name.zstr_tcopy();
        }

        Toggle* toggle = allocator::new(tmem, Toggle, { 
            .source_name = node.name,
            .label = label,
        });
        toggle.enabled = true;
        self.toggles.push(toggle);
        quicksort(&self.toggles);
    }

    Toggle* all = allocator::new(tmem, Toggle, { 
        .source_name = "",
        .label = "ALL".zstr_tcopy(),
        .enabled = true,
    });
    self.toggles.push(all);

    // Measure maximum label width for dynamic button sizing
    float max_label_width = 40f; // minimum for "ALL"
    foreach(toggle: self.toggles) {
        Vector2 text_size = rl::measureTextEx(self.fonts.bold, toggle.label, 14, 2f);
        if (text_size.x > max_label_width) {
            max_label_width = text_size.x;
        }
    }

    float button_width = max_label_width + 20f; // 10px padding each side
    const float BUTTON_HEIGHT = 25;
    const float BUTTON_SPACING = 28;

    foreach(i, toggle: self.toggles) {
        float x_pos = SCREEN_WIDTH - MARGIN - button_width;
        float y_pos = SCREEN_HEIGHT - MARGIN - ((i+1f) * BUTTON_SPACING);
        toggle.button = { x_pos, y_pos, button_width, BUTTON_HEIGHT };
    }
}

// TODO: add debounce to state, and update debounce counter to improve mouse click response 
fn void draw_topology_toggles(State* state)
{
    Toggle* all = state.toggles.last()!!;
    bool all_toggled;
    if (rl::checkCollisionPointRec(rl::getMousePosition(), all.button) && rl::isMouseButtonPressed(LEFT)) {
        all_toggled = true;
        all.enabled = !all.enabled;
        state.recalculate_layout = true;
    }

    foreach(toggle: state.toggles) {
        if (rl::checkCollisionPointRec(rl::getMousePosition(), toggle.button) && rl::isMouseButtonPressed(LEFT) && toggle.source_name.len > 0) {
            toggle.enabled = !toggle.enabled;
            state.recalculate_layout = true;
        } else if (all_toggled) {
            toggle.enabled = all.enabled;
        }
    }

    foreach(toggle: state.toggles) {
        rl::drawRectangleRec(toggle.button, toggle.enabled ? GREEN : RED);
        rl::drawTextEx(state.fonts.bold, toggle.label, {toggle.button.x + 5, toggle.button.y + 5}, 14, 2f, rl::BLACK);
        rl::drawRectangleLinesEx(toggle.button, 1, rl::DARKGRAY);
    }
}

const float ZOOM_SPEED = 0.1f;
const float MIN_ZOOM = 0.1f;
const float MAX_ZOOM = 4;

fn void Camera2D.mouse_zoom(&self)
{
    float mouseWheel = rl::getMouseWheelMove();
    if (mouseWheel != 0f) {
        Vector2 mousePos = rl::getMousePosition();
        Vector2 worldPos = rl::getScreenToWorld2D(mousePos, *self);
        self.zoom += mouseWheel * ZOOM_SPEED * self.zoom;
        if (self.zoom < MIN_ZOOM) self.zoom = MIN_ZOOM;
        if (self.zoom > MAX_ZOOM) self.zoom = MAX_ZOOM;
        Vector2 newWorldPos = rl::getScreenToWorld2D(mousePos, *self);
        self.target.x += (worldPos.x - newWorldPos.x);
        self.target.y += (worldPos.y - newWorldPos.y);
    }
}

fn void Camera2D.mouse_panning(&self, State* state)
{
    if (rl::isMouseButtonPressed(LEFT)) {
        state.is_panning = true;
        state.last_mouse_pos_world = rl::getScreenToWorld2D(rl::getMousePosition(), *self); 
    }
    if (rl::isMouseButtonReleased(LEFT)) {
        state.is_panning = false;
    }
    if (state.is_panning) {
        Vector2 current_mouse_pos_world = rl::getScreenToWorld2D(rl::getMousePosition(), *self);
        float delta_x = current_mouse_pos_world.x - state.last_mouse_pos_world.x;
        float delta_y = current_mouse_pos_world.y - state.last_mouse_pos_world.y;
        self.target.x -= delta_x;
        self.target.y -= delta_y;
    }

}

fn void Camera2D.handle_input(&self, State* state) 
{
    Vector2 mouse_world = rl::getScreenToWorld2D(rl::getMousePosition(), *self);
    Node* hovered = null;
    Topology* topo = state.active_topo();

    foreach (node: topo.nodes.tvalues()) {
        if (!state.is_node_visible(node)) continue;

        if (node.kind == STORE) {
            // Hit test for rectangular STORE nodes
            Rectangle rect = { node.x - STORE_RECT_W/2f, node.y - STORE_RECT_H/2f, STORE_RECT_W, STORE_RECT_H };
            if (rl::checkCollisionPointRec(mouse_world, rect)) {
                hovered = node;
                break;
            }
        } else {
            Vector2 node_center = { node.x, node.y };
            if (rl::checkCollisionPointCircle(mouse_world, node_center, NODE_RADIUS)) {
                hovered = node;
                break;
            }
        }
    }

    if (rl::isMouseButtonPressed(LEFT)) {
        if (hovered) {
            state.selected_node = hovered;
            state.compute_highlighted_nodes();
        } else if (!state.is_panning) {
            state.selected_node = null;
            state.compute_highlighted_nodes();
        }
    }
}

const float GLOW_THICKNESS = 4f;
const float STORE_RECT_W = 80f;   // width of STORE node rectangles
const float STORE_RECT_H = 40f;   // height of STORE node rectangles

fn void Node.draw(&self, State* state)
{
    rl::Color color;
    switch (self.kind) {
        case SOURCE: color = GREEN;
        case PROCESSOR: 
            if (self.is_join) {
                color = ORANGE;
            } else {
                color = self.is_stateful() ? RED : PURPLE;
            }
        case SINK: color = BLUE;
        case TOPIC: color = TEAL;
        case STORE: color = SILVER;
    }

    bool is_selected = (self == state.selected_node);
    bool is_in_highlight_set = !is_selected && state.is_highlighted(self);
    rl::Color glow_color = is_selected ? HIGHLIGHT_YELLOW : HIGHLIGHT_DIM;
    Vector2 center = { self.x, self.y };

    if (self.kind == STORE) {
        // Draw STORE nodes as rounded rectangles
        float rw = STORE_RECT_W;
        float rh = STORE_RECT_H;
        Rectangle rect = { self.x - rw/2f, self.y - rh/2f, rw, rh };

        if (is_selected || is_in_highlight_set) {
            Rectangle glow_rect = { rect.x - GLOW_THICKNESS, rect.y - GLOW_THICKNESS, rect.width + 2*GLOW_THICKNESS, rect.height + 2*GLOW_THICKNESS };
            rl::drawRectangleRounded(glow_rect, 0.3f, 4, glow_color);
        }
        rl::drawRectangleRounded(rect, 0.3f, 4, color);
        rl::drawRectangleRoundedLinesEx(rect, 0.3f, 4, 2f, GOLD);
    } else {
        // Draw regular nodes as circles
        rl::drawCircle((int)self.x, (int)self.y, NODE_RADIUS, color);

        float radius = NODE_RADIUS;
        if (is_selected || is_in_highlight_set) {
            rl::drawCircleV(center, radius + GLOW_THICKNESS, glow_color);
        }

        rl::drawCircleV(center, radius, color);
        rl::drawCircleLinesV(center, radius, GOLD);

        // Double ring for merged nodes (collapsed by topic)
        if (self.is_merged) {
            rl::drawCircleLinesV(center, radius + 4f, GOLD);
        }
    }

    ZString name = self.name.zstr_tcopy();
    int font_size = 16;
    int text_width = rl::measureText(name, font_size);

    float label_y;
    if (self.kind == STORE) {
        label_y = self.y + STORE_RECT_H / 2f;
    } else {
        label_y = self.y + NODE_RADIUS;
    }

    rl::drawTextEx(
        state.fonts.thin,
        name,
        { self.x - (text_width / 2f), label_y },
        font_size,
        3f,
        rl::WHITE,
    );
    if (self.kind == PROCESSOR && self.is_stateful()) {
        rl::drawTextEx(
            state.fonts.thin,
            self.stores[0].zstr_tcopy(),
            { self.x - (text_width / 2f), label_y + font_size },
            font_size,
            3f,
            rl::WHITE,
        );
    }
    if (self.kind == SINK && self.has_topics()) {
        rl::drawTextEx(
            state.fonts.thin,
            self.topics[0].zstr_tcopy(),
            { self.x - (text_width / 2f), label_y + font_size },
            font_size,
            3f,
            rl::WHITE,
        );
    }
    if (self.kind == SOURCE && self.has_topics()) {
        rl::drawTextEx(
            state.fonts.thin,
            self.topics[0].zstr_tcopy(),
            { self.x - (text_width / 2f), label_y + font_size },
            font_size,
            3f,
            rl::WHITE,
        );
    }
}

const float ARROW_SIZE = 15; 
const float GAP_DIST = NODE_RADIUS + ARROW_SIZE;
const float DASH_LENGTH = 10f;
const float DASH_GAP = 8f;

// Get the edge offset (radius for circles, half-rect for store rectangles)
fn float Node.edge_radius(&self) {
    if (self.kind == STORE) {
        // Approximate: use half the diagonal of the rectangle
        return math::max(STORE_RECT_W, STORE_RECT_H) / 2f;
    }
    return NODE_RADIUS;
}

fn void Node.connect(&self, Node other, State* state)
{
    Vector2 center_start = { self.x, self.y };
    Vector2 center_end = { other.x, other.y };
    Vector2 dir_vec = rl::vector2Subtract(center_end, center_start);
    float len = rl::vector2Length(dir_vec);
    if (len < 1f) return;
    bool is_highlighted = state.is_highlighted(self) && state.is_highlighted(&other);
    bool is_store_edge = (self.kind == STORE || other.kind == STORE);

    rl::Color color;
    float thickness;
    if (is_highlighted) {
        color = HIGHLIGHT_YELLOW;
        thickness = 7f;
    } else if (is_store_edge) {
        color = ORANGE;
        thickness = 3f;
    } else {
        color = GOLD;
        thickness = 5f;
    }

    float start_radius = self.edge_radius();
    float end_radius = other.edge_radius();

    int layer_diff = math::abs(other.layer - self.layer);
    bool is_long_edge = (layer_diff > LONG_EDGE_LAYER_THRESHOLD) && !is_store_edge;

    if (is_store_edge) {
        // Dashed straight line (no arrowhead) for store relationships
        Vector2 start_pos = rl::vector2Lerp(center_start, center_end, start_radius / len);
        Vector2 end_pos = rl::vector2Lerp(center_start, center_end, 1f - (end_radius / len));
        draw_dashed_line(start_pos, end_pos, thickness, color);
    } else if (is_long_edge) {
        // Curved bezier edge for long-span connections
        Vector2 midpoint = rl::vector2Lerp(center_start, center_end, 0.5f);
        // Perpendicular unit vector (pointing "upward" in screen coords, i.e. negative Y)
        Vector2 perp = { -dir_vec.y / len, dir_vec.x / len };
        // Scale offset with layer difference, but cap it
        float offset = BEZIER_CURVE_OFFSET * (float)(layer_diff - LONG_EDGE_LAYER_THRESHOLD);
        offset = math::min(offset, MAX_BEZIER_OFFSET);
        // Choose curve direction: bow upward (negative Y direction)
        // If perp.y > 0, flip it so the curve always bows upward
        if (perp.y > 0f) {
            perp = { -perp.x, -perp.y };
        }
        Vector2 control = rl::vector2Add(midpoint, rl::vector2Scale(perp, offset));

        // Tangent at t=0 of quadratic bezier: 2*(C - P0)
        Vector2 tangent_start_raw = rl::vector2Subtract(control, center_start);
        float tangent_start_len = rl::vector2Length(tangent_start_raw);
        // Tangent at t=1 of quadratic bezier: 2*(P1 - C)
        Vector2 tangent_end_raw = rl::vector2Subtract(center_end, control);
        float tangent_end_len = rl::vector2Length(tangent_end_raw);

        if (tangent_start_len < 1f || tangent_end_len < 1f) return;

        Vector2 tangent_start_unit = rl::vector2Scale(tangent_start_raw, 1f / tangent_start_len);
        Vector2 tangent_end_unit = rl::vector2Scale(tangent_end_raw, 1f / tangent_end_len);

        // Offset start/end from node edges along the bezier tangent direction
        Vector2 start_pos = rl::vector2Add(center_start, rl::vector2Scale(tangent_start_unit, start_radius));
        Vector2 arrow_tip = rl::vector2Subtract(center_end, rl::vector2Scale(tangent_end_unit, end_radius));
        Vector2 arrow_base = rl::vector2Subtract(center_end, rl::vector2Scale(tangent_end_unit, end_radius + ARROW_SIZE));

        rl::drawSplineSegmentBezierQuadratic(start_pos, control, arrow_base, thickness, color);
        draw_arrowhead(arrow_tip, arrow_base, ARROW_SIZE, color);
    } else {
        // Straight line for short-span edges
        Vector2 start_pos = rl::vector2Lerp(center_start, center_end, start_radius / len);
        Vector2 arrow_tip = rl::vector2Lerp(center_start, center_end, 1f - (end_radius / len));
        Vector2 arrow_base = rl::vector2Lerp(center_start, center_end, (1f - (end_radius / len)) - (ARROW_SIZE / len));
        rl::drawLineEx(start_pos, arrow_base, thickness, color);
        draw_arrowhead(arrow_tip, arrow_base, ARROW_SIZE, color);
    }
}

fn void draw_dashed_line(Vector2 start, Vector2 end, float thickness, rl::Color color)
{
    Vector2 dir_vec = rl::vector2Subtract(end, start);
    float total_len = rl::vector2Length(dir_vec);
    if (total_len < 1f) return;
    Vector2 unit = rl::vector2Scale(dir_vec, 1f / total_len);
    float t = 0f;
    while (t < total_len) {
        float seg_end = t + DASH_LENGTH;
        if (seg_end > total_len) seg_end = total_len;
        Vector2 seg_start = rl::vector2Add(start, rl::vector2Scale(unit, t));
        Vector2 seg_end_pt = rl::vector2Add(start, rl::vector2Scale(unit, seg_end));
        rl::drawLineEx(seg_start, seg_end_pt, thickness, color);
        t += DASH_LENGTH + DASH_GAP;
    }
}

fn void draw_arrowhead(Vector2 tip, Vector2 base, float size, rl::Color color)
{
    Vector2 dir_vector = rl::vector2Subtract(tip, base); 
    float length = rl::vector2Length(dir_vector);
    if (length < 1f) return;
    Vector2 unit_dir = rl::vector2Scale(dir_vector, 1f / length);
    Vector2 unit_perp = { -unit_dir.y, unit_dir.x };
    Vector2 wing1 = rl::vector2Add(base, rl::vector2Scale(unit_perp, size * 0.5f));
    Vector2 wing2 = rl::vector2Subtract(base, rl::vector2Scale(unit_perp, size * 0.5f));
    rl::drawTriangle(tip, wing2, wing1, color);
}

fn void graph(State* state)
{
    Topology* topo = state.active_topo();
    List{Node*} queue;
    state.max_layer = 0;
    state.max_node_width = 0;

    // initialize
    foreach(node: topo.nodes.tvalues()) {
        if (!state.is_node_visible(node)) {
            node.layer = -2; // invisible
            continue;
        }

        int font_size = 16;
        Vector2 text_size = rl::measureTextEx(
            state.fonts.thin,
            node.name.zstr_tcopy(),
            font_size,
            3f,
        );
        float required_width = 2f * NODE_RADIUS + text_size.x;
        if (required_width > state.max_node_width) {
            state.max_node_width = required_width;
        }

        node.layer = 0;
        // Only true root nodes (SOURCE nodes with no upstream) seed the BFS
        if (node.kind == SOURCE && node.upstream.len() == 0) {
            queue.push(node);
        }
    }

    // BFS longest-path layering
    // Note: Kafka topologies can contain cycles (e.g. sub-topo A writes to a topic
    // that sub-topo B reads, and B writes to a topic that A reads). We cap the layer
    // to the total node count to guarantee termination.
    int max_possible_layer = (int)topo.nodes.count;
    while (queue.len() > 0) {
        Node* cur = queue.pop()!!;

        if (cur.layer > state.max_layer) {
            state.max_layer = cur.layer;
        }

        foreach(dsname: cur.downstream) {
            Node*? ds = topo.nodes.get(dsname);
            if (catch ds) continue;
            if (ds.layer == -2) continue;

            int potential_layer = cur.layer + 1;

            // Cap layer to prevent infinite loops from topology cycles
            if (potential_layer > max_possible_layer) continue;

            if (potential_layer > ds.layer) {
                ds.layer = potential_layer;
                queue.push(ds);

                if (ds.layer > state.max_layer) {
                    state.max_layer = ds.layer;
                }
            }
        }
    }

    // Pull nodes closer to their downstream to minimize long-span edges.
    // Process from highest layer to lowest: for each node, increase its layer
    // to min(downstream.layer) - 1 if that is higher than its current layer.
    // This cascades correctly because downstream nodes are processed first.
    compact_layers(state);
    collapse_empty_layers(state);
}

fn void compact_layers(State* state)
{
    Topology* topo = state.active_topo();

    // Collect visible nodes sorted by layer descending (highest first)
    Nodes all_nodes;
    all_nodes.tinit();
    foreach(node: topo.nodes.tvalues()) {
        if (node.layer >= 0) {
            all_nodes.push(node);
        }
    }
    quicksort(&all_nodes, &cmp_layer_desc);

    // Single reverse pass: pull each node toward its downstream neighbors
    foreach(node: all_nodes) {
        if (node.downstream.len() == 0) continue;

        int min_ds_layer = (int)state.max_layer + 1;
        foreach(dsname: node.downstream) {
            Node*? ds = topo.nodes.get(dsname);
            if (catch ds) continue;
            if (ds.layer < 0) continue; // invisible
            if (ds.layer < min_ds_layer) {
                min_ds_layer = ds.layer;
            }
        }

        int target = min_ds_layer - 1;
        if (target > node.layer) {
            node.layer = target;
        }
    }
}

fn int cmp_layer_desc(Node* a, Node* b) {
    if (a.layer > b.layer) return -1;
    if (a.layer < b.layer) return 1;
    return 0;
}

// Remove empty layer gaps by renumbering layers contiguously.
// E.g. used layers {0, 1, 8, 9, 22, 23} become {0, 1, 2, 3, 4, 5}.
fn void collapse_empty_layers(State* state)
{
    Topology* topo = state.active_topo();

    // Collect the set of used layer numbers
    List{int} used_layers;
    used_layers.tinit();
    foreach(node: topo.nodes.tvalues()) {
        if (node.layer < 0) continue;
        // Add only if not already present
        bool found = false;
        foreach(l: used_layers) {
            if (l == node.layer) { found = true; break; }
        }
        if (!found) {
            used_layers.push(node.layer);
        }
    }

    if (used_layers.len() == 0) return;

    // Sort ascending
    quicksort(&used_layers);

    // Remap each node's layer to its index in the sorted unique list
    foreach(node: topo.nodes.tvalues()) {
        if (node.layer < 0) continue;
        foreach(i, l: used_layers) {
            if (l == node.layer) {
                node.layer = (int)i;
                break;
            }
        }
    }

    // Update max_layer
    state.max_layer = used_layers.len() - 1;
}

fn NodesByLayer calculate_positions(State* state)
{
    Topology* topo = state.active_topo();
    NodesByLayer layers;
    for (int i; i <= state.max_layer; i++) {
            Nodes n;
            n.tinit();
            layers.push(n);
    }
    foreach(node: topo.nodes.tvalues()) {
        if (!state.is_node_visible(node)) continue;
        if (node.layer >= 0 && node.layer <= state.max_layer) {
            layers[node.layer].push(node);
        }
    } 

    const float DRAW_WIDTH = SCREEN_WIDTH - (2f * MARGIN);
    const float DRAW_HEIGHT = SCREEN_HEIGHT - (2f * MARGIN);
    float layer_step_size = 0f;
    float required_min_step = state.max_node_width + NODE_PADDING;

    if (state.max_layer > 0) {
        float calculated_step = DRAW_WIDTH / state.max_layer;

        layer_step_size = math::max(calculated_step, required_min_step);
    } else {
        layer_step_size = DRAW_WIDTH;
    }

    for (int i; i <= state.max_layer; i++) {
        Nodes layer_nodes = layers[i];

        // Edge crossing minimization (barycenter)
        if (i > 0) {
            Nodes prev_layer_nodes = layers[(usz)i-1];
            foreach(node: layer_nodes) {
                float total_y;
                usz count;
                foreach(usname: node.upstream) {
                    Node*? us = topo.nodes.get(usname);
                    if (catch us) continue;
                    if (us.layer == (i - 1)) {
                        total_y += us.y;
                        count++;
                    }
                }
                node.barycenter = (count > 0) ? (total_y / count) : node.y;
            }
            quicksort(&layer_nodes, &cmp_barycenter);
        }
        // Edge crossing minimization (barycenter) end

        float layer_pos_x = MARGIN + i * layer_step_size;
        if (state.max_layer == 0) layer_pos_x = MARGIN + DRAW_WIDTH / 2f;
        float total_vertical_space = layer_nodes.len() * NODE_VERTICAL_STEP - NODE_PADDING;
        float offset_y = (DRAW_HEIGHT - total_vertical_space) / 2f;
        float current_y = MARGIN + offset_y + NODE_RADIUS;

        foreach(j, Node * node : layer_nodes) {
            node.x = (int) layer_pos_x;
            node.y = (int) current_y;
            current_y += NODE_VERTICAL_STEP;
        }
    }
    return layers;
}

fn int cmp_barycenter(Node* a, Node* b) {
    if (a.barycenter < b.barycenter) return -1;
    if (a.barycenter > b.barycenter) return 1;
    return 0;
}

