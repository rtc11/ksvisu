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

alias Nodes = List{Node*};
alias NodesByLayer = List{Nodes};

struct Fonts {
    Font regular;
    Font thin;
    Font bold;
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
        .regular = rl::loadFont("resources/JetBrainsMono-Regular.ttf"),
        .thin = rl::loadFont("resources/JetBrainsMonoNL-Thin.ttf"),
        .bold = rl::loadFont("resources/JetBrainsMono-Bold.ttf"),
    };

    State state = { 
        .topo = topo,
        .fonts = fonts, 
    };

    state.setup_sub_topology_buttons(topo);
    graph(&state);
    NodesByLayer layers = calculate_positions(state);

    while (!rl::windowShouldClose()) {
        if (rl::isKeyPressed(rl::KEY_ENTER)) break;

        camera.mouse_zoom();
        camera.mouse_panning(&state);

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
                node.connect(*downstream);
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
            .label = string::tformat_zstr("%d", node.sub_topology) }
        );
        if (sub_id == 3) toggle.enabled = true;
        self.toggles.push(toggle);
        quicksort(&self.toggles);
    }

    const float BUTTON_WIDTH = 60;
    const float BUTTON_HEIGHT = 30;
    const float BUTTON_SPACING = 35;

    foreach(i, toggle: self.toggles) {
        float x_pos = SCREEN_WIDTH - MARGIN - BUTTON_WIDTH;
        float y_pos = SCREEN_HEIGHT - MARGIN - ((i+1f) * BUTTON_SPACING);
        toggle.button = { x_pos, y_pos, BUTTON_WIDTH, BUTTON_HEIGHT };
    }
}

struct Toggle
{
    ZString label;
    int id;
    Rectangle button;
    bool enabled;
}

fn bool Toggle.less(&self, Toggle* other) => self.id < other.id;

struct State
{
    Topology topo;
    List{Toggle*} toggles;
    Fonts fonts;
    usz max_layer;
    bool is_panning;
    Vector2 last_mouse_pos_world;
}

fn void draw_topology_toggles(State* state)
{
    foreach(toggle: state.toggles) {
        if (rl::checkCollisionPointRec(rl::getMousePosition(), toggle.button)) {
            if (rl::isMouseButtonPressed(LEFT)) {
                toggle.enabled = !toggle.enabled;
            }
        }

        rl::Color but_color = toggle.enabled ? GREEN : RED;
        rl::Color color = toggle.enabled ? GREEN : RED;
        rl::drawRectangleRec(toggle.button, but_color);
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

fn void Node.draw(&self, State* state)
{
    rl::Color color;
    switch (self.kind) {
        case SOURCE: color = GREEN;
        case PROCESSOR: color = self.is_stateful() ? RED : PURPLE;  
        case SINK: color = BLUE;
    }
    rl::drawCircle(self.x, self.y, NODE_RADIUS, color);
    rl::drawCircleLines(self.x, self.y, NODE_RADIUS, GOLD);
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
}

fn void Node.connect(&self, Node other)
{
    Vector2 startPos = {(float) self.x + NODE_RADIUS, (float) self.y };
    Vector2 endPos = {(float) other.x - NODE_RADIUS, (float) other.y };
    rl::drawLineEx(startPos, endPos, 5, GOLD);
}

fn void graph(State* state)
{
    List{Node*} queue;

    foreach(node: state.topo.nodes.tvalues()) {
        bool include;
        foreach(toggle : state.toggles) {
            if (toggle.id == node.sub_topology && toggle.enabled) {
                include = true;
                break;
            }
        }
        if (!include) {
            node.layer = -2;
            continue;
        }
        switch (node.kind) {
            case SOURCE: queue.push(node);
            default: node.layer = -1;
        }
    }

    // BFS
    while (queue.len() > 0) {
        Node* current_node = queue.pop()!!;
        int next_layer = current_node.layer + 1;
        if (current_node.layer > state.max_layer) state.max_layer = current_node.layer;

        foreach(downstream_name: current_node.downstream) {
            Node*? downstream = state.topo.nodes.get(downstream_name);
            if (catch downstream) continue;
            if (downstream.layer < next_layer) {
                downstream.layer = next_layer;
                queue.push(downstream);
            }
        }
    }
}

fn NodesByLayer calculate_positions(State state)
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
    if (state.max_layer > 0) layer_step_size = DRAW_WIDTH / (float)state.max_layer;

    for (int i; i <= state.max_layer; i++) {
        Nodes layer_nodes = layers[i];
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

