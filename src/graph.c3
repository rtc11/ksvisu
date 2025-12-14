module ksvisu;

import std::io;
import std::math;
import std::collections::list;
import std::collections::map;
import std::sort;
import raylib5;

const usz SCREEN_WIDTH = 1600;
const usz SCREEN_HEIGHT = 1200;
const usz NODE_RADIUS = 50;
const usz NODE_PADDING = 50;
const usz MARGIN = NODE_PADDING;
const usz NODE_VERTICAL_STEP = (2 * NODE_RADIUS) + NODE_PADDING;

const rl::Color BG = { 20, 28, 33, 255};
const rl::Color BODY = { 13, 18, 20, 255};
const rl::Color GREEN = { 37, 135, 43, 255};
const rl::Color RED = { 200, 50, 50, 255};
const rl::Color PURPLE = { 181, 33, 127, 255};
const rl::Color BLUE = { 50, 100, 200, 255};
const rl::Color GOLD = { 218, 165, 35, 255};
const rl::Color HIGHLIGHT_YELLOW = { 255, 255, 0, 255};

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
    List{Toggle*} toggles;
    Fonts fonts;
    usz max_layer;           // max layers in the (enabled) sub-topologies
    bool is_panning;         // when left mouse is pressed and screen is dragged
    Vector2 last_mouse_pos_world; 
    bool recalculate_layout; // when to recalculate graph and calculate_positions
    float max_node_width;    // max horizontal space required by a node's label
    Node* selected_node;
}


struct Toggle
{
    ZString label;
    int id;
    Rectangle button;
    bool enabled;
}

fn bool Toggle.less(&self, Toggle* other) => self.id < other.id; // used in quicksort

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

    state.setup_sub_topology_buttons(topo);

    while (!rl::windowShouldClose()) {
        if (rl::isKeyPressed(rl::KEY_ENTER)) break;

        camera.mouse_zoom();
        camera.mouse_panning(&state);

        camera.handle_input(&state);

        if (state.recalculate_layout) {
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
    foreach (node: state.topo.nodes.tvalues()) {
        bool node_is_visible;

        foreach(toggle : state.toggles) {
            if (toggle.id == node.sub_topology && toggle.enabled) {
                node_is_visible = true;
                break;
            }
        }

        if (!node_is_visible) continue;

        foreach(downstream_name: node.downstream) {
            Node*? downstream = state.topo.nodes[downstream_name];
            if (catch downstream) continue;

            bool downstream_is_visible;
            foreach(toggle: state.toggles) {
                if (toggle.id == downstream.sub_topology && toggle.enabled) {
                    downstream_is_visible = true;  
                    break;
                }
            }

            if (downstream_is_visible) {
                node.connect(*downstream, state);
            }
        }
    };

    foreach (node: state.topo.nodes.tvalues()) {
        bool should_draw;
        foreach(toggle : state.toggles) {
            if (toggle.id == node.sub_topology && toggle.enabled) {
                should_draw = true;
                break;
            }
        }
        if (should_draw) {
            node.draw(state);
        }
    }
}

fn void State.setup_sub_topology_buttons(&self, Topology topo)
{
    foreach(node: topo.nodes.tvalues()) {
        int sub_id = node.sub_topology; 
        bool already_exists;
        foreach(existing_toggle: self.toggles) {
            if (existing_toggle.id == sub_id) {
                already_exists = true;
                break;
            }
        }
        if(already_exists) continue;

        Toggle* toggle = allocator::new(tmem, Toggle, { 
            .id = node.sub_topology,
            .label = string::tformat_zstr("%d", node.sub_topology), 
        });
        // if (sub_id == 3) toggle.enabled = true;
        toggle.enabled = true;
        self.toggles.push(toggle);
        quicksort(&self.toggles);
    }

    Toggle* all = allocator::new(tmem, Toggle, { 
        .id = 1000,
        .label = "ALL".zstr_tcopy(),
        .enabled = true,
    });
    self.toggles.push(all);

    const float BUTTON_WIDTH = 60;
    const float BUTTON_HEIGHT = 30;
    const float BUTTON_SPACING = 35;

    foreach(i, toggle: self.toggles) {
        float x_pos = SCREEN_WIDTH - MARGIN - BUTTON_WIDTH;
        float y_pos = SCREEN_HEIGHT - MARGIN - ((i+1f) * BUTTON_SPACING);
        toggle.button = { x_pos, y_pos, BUTTON_WIDTH, BUTTON_HEIGHT };
    }
}

// TODO: add debounce to state, and update debounce counter to improve mouse click response 
fn void draw_topology_toggles(State* state)
{
    Toggle* all = state.toggles.last()!!;
    bool all_toggeled;
    if (rl::checkCollisionPointRec(rl::getMousePosition(), all.button) && rl::isMouseButtonPressed(LEFT)) {
        all_toggeled = true;
        all.enabled = !all.enabled;
        state.recalculate_layout = true;
    }

    foreach(toggle: state.toggles) {
        if (rl::checkCollisionPointRec(rl::getMousePosition(), toggle.button) && rl::isMouseButtonPressed(LEFT) && toggle.id != 1000) {
            toggle.enabled = !toggle.enabled;
            state.recalculate_layout = true;
        } else if (all_toggeled) {
            toggle.enabled = all.enabled;
        }
    }

    foreach(toggle: state.toggles) {
        rl::drawRectangleRec(toggle.button, toggle.enabled ? GREEN : RED);
        rl::drawTextEx(state.fonts.bold, toggle.label, {toggle.button.x + 20, toggle.button.y + 5}, 20, 4f, rl::BLACK);
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

    foreach (node: state.topo.nodes.tvalues()) {
        bool is_visible;
        foreach (toggle : state.toggles) {
            if (toggle.id == node.sub_topology && toggle.enabled) {
                is_visible = true;
                break;
            }
        }

        if (!is_visible) continue;

        Vector2 node_center = { (float)node.x, (float)node.y };

        if (rl::checkCollisionPointCircle(mouse_world, node_center, (float)NODE_RADIUS)) {
            hovered = node;
            break;
        }
    }

    if (rl::isMouseButtonPressed(LEFT)) {
        if (hovered) {
            state.selected_node = hovered;
        } else if (!state.is_panning) {
            state.selected_node = null;
        }
    }
}

const float GLOW_THICKNESS = 4f;

fn void Node.draw(&self, State* state)
{
    rl::Color color;
    switch (self.kind) {
        case SOURCE: color = GREEN;
        case PROCESSOR: color = self.is_stateful() ? RED : PURPLE;  
        case SINK: color = BLUE;
    }
    rl::drawCircle(self.x, self.y, NODE_RADIUS, color);

    bool is_selected = (self == state.selected_node);
    float radius = (float) NODE_RADIUS;
    Vector2 center = { (float)self.x, (float)self.y };

    if (is_selected) {
        rl::drawCircleV(center, radius + GLOW_THICKNESS, HIGHLIGHT_YELLOW);
    }

    rl::drawCircleV(center, radius, color);
    rl::drawCircleLinesV(center, radius, GOLD);

    ZString name = self.name.zstr_tcopy();
    int font_size = 16;
    int text_width = rl::measureText(name, font_size);
    rl::drawTextEx(
        state.fonts.thin,
        name,
        { self.x - (text_width / 2f), (float)self.y + NODE_RADIUS },
        (float) font_size,
        3f,
        rl::WHITE,
    );
    if (self.kind == PROCESSOR && self.is_stateful()) {
        rl::drawTextEx(
            state.fonts.thin,
            self.stores[0].zstr_tcopy(),
            { self.x - (text_width / 2f), (float)self.y + NODE_RADIUS + font_size },
            (float) font_size,
            3f,
            rl::WHITE,
        );
    }
}

const float ARROW_SIZE = 15; 
const float GAP_DIST = NODE_RADIUS + ARROW_SIZE;

fn void Node.connect(&self, Node other, State* state)
{
    Vector2 center_start = { (float)self.x, (float)self.y };
    Vector2 center_end = { (float)other.x, (float)other.y };
    Vector2 vec_to_other = rl::vector2Subtract(center_end, center_start);
    float dist = rl::vector2Length(vec_to_other);
    if (dist == 0f) return;
    Vector2 normal_vec = rl::vector2Scale(vec_to_other, 1f / dist);
    Vector2 start_pos = rl::vector2Add(center_start, rl::vector2Scale(normal_vec, (float)NODE_RADIUS));
    Vector2 line_end_pos = rl::vector2Subtract(center_end, rl::vector2Scale(normal_vec, ARROW_SIZE));
    bool is_highlighted;
    if (state.selected_node) {
        if (self == state.selected_node || &other == state.selected_node) {
            is_highlighted = true;
        }
    }
    rl::Color color = is_highlighted ? HIGHLIGHT_YELLOW : GOLD;
    float thickness = is_highlighted ? 7f : 5f;
    rl::drawLineEx(start_pos, line_end_pos, thickness, color);

    Vector2 arrow_dest = rl::vector2Subtract(center_end, rl::vector2Scale(normal_vec, (float)NODE_RADIUS));
    draw_arrowhead(arrow_dest, line_end_pos, ARROW_SIZE, color);
    // Vector2 startPos = {(float) self.x + NODE_RADIUS, (float) self.y };
    // Vector2 endPos = {(float) other.x - NODE_RADIUS, (float) other.y };
    // rl::drawLineEx(startPos, endPos, 5, GOLD);
}

fn void draw_arrowhead(Vector2 end, Vector2 start, float size, rl::Color color)
{
    Vector2 dir = rl::vector2Subtract(end, start);
    float length = rl::vector2Length(dir);
    if (length == 0f) return;
    dir = rl::vector2Scale(dir, 1 / length);
    Vector2 base = rl::vector2Subtract(end, rl::vector2Scale(dir, size));
    Vector2 perp = { -dir.y, dir.x };
    Vector2 wing1 = rl::vector2Add(base, rl::vector2Scale(perp, size * 0.5));
    Vector2 wing2 = rl::vector2Subtract(base, rl::vector2Scale(perp, size * 0.5));
    rl::drawTriangle(end, wing1, wing2, color);
}

fn void graph(State* state)
{
    List{Node*} queue;
    state.max_layer = 0;
    state.max_node_width = 0;

    // initialize
    foreach(node: state.topo.nodes.tvalues()) {
        bool include;
        foreach(toggle : state.toggles) {
            if (toggle.id == node.sub_topology && toggle.enabled) {
                include = true;
                break;
            }
        }

        if (!include) {
            node.layer = -2; // invisible
            continue;
        }

        int font_size = 16;
        Vector2 text_size = rl::measureTextEx(
            state.fonts.thin,
            node.name.zstr_tcopy(),
            (float) font_size,
            3f,
        );
        float required_width = 2f * NODE_RADIUS + text_size.x;
        if (required_width > state.max_node_width) {
            state.max_node_width = required_width;
        }

        node.layer = 0;
        if (node.kind == SOURCE) {
            queue.push(node);
        }
    }

    // BFS - Longest path - with cycle breaking
    while (queue.len() > 0) {
        Node* cur = queue.pop()!!;

        if (cur.layer > state.max_layer) {
            state.max_layer = cur.layer;
        }

        foreach(dsname: cur.downstream) {
            Node*? ds = state.topo.nodes.get(dsname);
            if (catch ds) continue;
            if (ds.layer == -2) continue;

            int potential_layer = cur.layer + 1;

            if (potential_layer > ds.layer) {
                ds.layer = potential_layer;
                queue.push(ds);

                if (ds.layer > state.max_layer) {
                    state.max_layer = ds.layer;
                }
            }
        }
    }

    // manual cycle layer adjustment start
    Node*[] all_nodes = state.topo.nodes.tvalues(); 
    usz max_iter = all_nodes.len * 2;
    bool changed = true;
    foreach (node : all_nodes) {
        if (node.kind != SOURCE && node.layer != -2) {
            node.layer = -1; // reset
        }
    }
    int iter_count = 0;
    while (changed && iter_count < max_iter) {
        changed = false;
        iter_count++;

        foreach(node: all_nodes){
            if (node.layer == -2) continue; // invisible
            if (node.kind == SOURCE) {
                if (node.layer != 0) {
                    node.layer = 0;
                    changed = true;
                }
                continue;
            }
            int max_us_layer = -1;
            foreach(usname: node.upstream) {
                Node*? us = state.topo.nodes.get(usname);
                if (catch us) continue;
                if (us.layer < 0) continue;
                if (us.layer > max_us_layer) max_us_layer = us.layer;
            }
            int required_layer = max_us_layer + 1;
            if (required_layer > node.layer) {
                node.layer = required_layer;
                changed = true;
            }
        }
    }
    
    state.max_layer = 0;
    foreach(node : all_nodes) {
        if (node.layer > state.max_layer) {
            state.max_layer = node.layer;
        }
    }
    // manual cycle layer adjustment end
}

fn NodesByLayer calculate_positions(State* state)
{
    NodesByLayer layers;
    layers.tinit(state.max_layer + 1);
    foreach(node: state.topo.nodes.tvalues()) {

        bool include;
        foreach(toggle : state.toggles) {
            if (toggle.id == node.sub_topology && toggle.enabled) {
                include = true;
                break;
            }
        }
        if (!include) continue;
        if (node.layer >= 0 && node.layer <= state.max_layer) {
            layers[node.layer].push(node);
        }
    } 

    const float DRAW_WIDTH = SCREEN_WIDTH - (2f * MARGIN);
    const float DRAW_HEIGHT = SCREEN_HEIGHT - (2f * MARGIN);
    float layer_step_size = 0f;
    float required_min_step = state.max_node_width + NODE_PADDING;

    if (state.max_layer > 0) {
        float calculated_step = DRAW_WIDTH / (float) state.max_layer;

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
                    Node*? us = state.topo.nodes.get(usname);
                    if (catch us) continue;
                    if (us.layer == (i - 1)) {
                        total_y += (float) us.y;
                        count++;
                    }
                }
                node.barycenter = (count > 0) ? (total_y / (float) count) : node.y;
            }
            quicksort(&layer_nodes, &cmp_barycenter);
        }

        float layer_pos_x = (float)MARGIN + (float)i * layer_step_size;
        if (state.max_layer == 0) layer_pos_x = MARGIN + DRAW_WIDTH / 2f;
        usz total_vertical_space = layer_nodes.len() * NODE_VERTICAL_STEP - NODE_PADDING;
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

