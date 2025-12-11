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

fn void visualize(Topology topo, int sub_topology_id = 3)
{
    rl::setConfigFlags(MSAA_4X_HINT);
    rl::initWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "Kafka Streams Topology Visualizer");
    rl::setMouseCursor(CROSSHAIR);

    Camera2D camera = {
        .offset = { SCREEN_WIDTH / 2f, SCREEN_HEIGHT / 2f },
        .target = { SCREEN_WIDTH / 2f, SCREEN_HEIGHT / 2f },
        .zoom = 1f,
    };

    Font font = rl::loadFont("resources/JetBrainsMonoNL-Thin.ttf");
    if (!font.texture.id) font = rl::getFontDefault();

    bool is_panning;
    Vector2 last_mouse_pos_world;

    int max_layer = graph(topo, sub_topology_id);
    NodesByLayer layers = calculate_positions(topo, max_layer, sub_topology_id);

    State state = { 
        .topo = topo,
        .font = font, 
    };
    state.setup_sub_topology_buttons(topo);

    while (!rl::windowShouldClose()) {
        if (rl::isKeyPressed(rl::KEY_ENTER)) break;

        camera.mouse_zoom();
        camera.mouse_panning(&is_panning, &last_mouse_pos_world);

        rl::beginDrawing();
        rl::clearBackground(BG);
        rl::drawRectangleRec({MARGIN, MARGIN, SCREEN_WIDTH-(2*MARGIN), SCREEN_HEIGHT-(2*MARGIN)}, BODY);

        rl::beginMode2D(camera);
        draw_subtopology(state);
        rl::endMode2D();

        rl::drawText(string::tformat_zstr("Zoom: %.2f", camera.zoom), 10, 10, 20, rl::WHITE);
        draw_topology_toggles(state);

        rl::endDrawing();
    }
    rl::closeWindow();
}

fn void draw_subtopology(State state)
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
            node.draw(state.font);
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
    Font font;
}

fn void draw_topology_toggles(State state)
{
    foreach(toggle: state.toggles) {
        if (rl::checkCollisionPointRec(rl::getMousePosition(), toggle.button)) {
            if (rl::isMouseButtonPressed(LEFT)) {
                toggle.enabled = !toggle.enabled;
            }
        }

        rl::Color but_color = toggle.enabled ? GREEN : RED;
        // rl::Color txt_color = toggle.enabled ? rl::DARKGREEN : rl::MAROON;
        rl::Color txt_color = rl::BLACK;
        rl::Color color = toggle.enabled ? GREEN : RED;
        rl::drawRectangleRec(toggle.button, but_color);
        rl::drawText(toggle.label, (int)toggle.button.x + 10, (int)toggle.button.y + 10, 20, txt_color);
        // rl::drawTextEx(rl::getFontDefault(), toggle.label, toggle.button.pos + 10, 16, 3f, txt_color);
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

fn void Camera2D.mouse_panning(&self, bool* is_panning, Vector2* last_mouse_pos_world)
{
    if (rl::isMouseButtonPressed(LEFT)) {
        *is_panning = true;
        *last_mouse_pos_world = rl::getScreenToWorld2D(rl::getMousePosition(), *self); 
    }
    if (rl::isMouseButtonReleased(LEFT)) {
        *is_panning = false;
    }
    if (*is_panning) {
        Vector2 current_mouse_pos_world = rl::getScreenToWorld2D(rl::getMousePosition(), *self);
        float delta_x = current_mouse_pos_world.x - last_mouse_pos_world.x;
        float delta_y = current_mouse_pos_world.y - last_mouse_pos_world.y;
        self.target.x -= delta_x;
        self.target.y -= delta_y;
    }
}

fn void Node.draw(&self, Font font, int font_size = 16)
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
    int text_width = rl::measureText(name, font_size);
    rl::drawTextEx(
        font,
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

fn int graph(Topology topo, int sub_topology_id = 0)
{
    List{Node*} queue;
    int max_layer;
    foreach(node: topo.nodes.tvalues()) {
        if (node.sub_topology != sub_topology_id) {
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
        if (current_node.layer > max_layer) max_layer = current_node.layer;

        foreach(downstream_name: current_node.downstream) {
            Node*? downstream = topo.nodes.get(downstream_name);
            if (catch downstream) continue;
            if (downstream.layer < next_layer) {
                downstream.layer = next_layer;
                queue.push(downstream);
            }
        }
    }
    io::printfn("max_layer: %d", max_layer);
    return max_layer;
}

fn NodesByLayer calculate_positions(Topology topo, usz max_layer, int sub_topology_id = 0)
{
    NodesByLayer layers;
    layers.tinit(max_layer + 1);
    foreach(node: topo.nodes.tvalues()) {
        if (node.sub_topology != sub_topology_id) continue;
        if (node.layer >= 0 && node.layer <= max_layer) {
            layers[node.layer].push(node);
        }
    } 
    float layer_step_size = 0f;
    if (max_layer > 0) {
        float available_width = (float)SCREEN_WIDTH - (2f * MARGIN); 
        layer_step_size = available_width / (float)max_layer;
    }
    for (int i; i <= max_layer; i++) {
        Nodes layer_nodes = layers[i];
        float layer_pos_x = (float)MARGIN + (float)i * layer_step_size;
        if (max_layer == 0) {
            layer_pos_x = (float)SCREEN_WIDTH / 2f;
        }
        usz total_vertical_space = layer_nodes.len() * NODE_VERTICAL_STEP - NODE_PADDING;
        usz offset_for_centering = (SCREEN_HEIGHT - total_vertical_space) / 2;
        usz current_y = offset_for_centering + NODE_RADIUS;
        if (current_y < MARGIN) {
            current_y = MARGIN;
        }
        foreach(j, Node * node : layer_nodes) {
            node.x = (int) layer_pos_x;
            node.y = (int) current_y;
            current_y += NODE_VERTICAL_STEP;
        }
    }
    return layers;
}

