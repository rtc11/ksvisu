module ksvisu;

import std::collections::list;
import std::collections::map;

const int LAYER_HEIGHT = 100;
const int NODE_WIDTH = 50;

fn void graph(Topology topo)
{
    // INIT
    List{Node*} queue;
    topo.nodes.@each(; String name, Node* node) {
        if (node.kind == SOURCE) {
            node.layer = 0;
            queue.push(node);
        }
    };

    // BFS
    while (queue.len() > 0) {
        Node* current_node = queue.pop()!!;
        int next_layer = current_node.layer + 1;
        foreach(downstream_name: current_node.downstream) {
            Node* downstream = topo.nodes.get(downstream_name)!!;
            if (downstream.layer < next_layer) {
                downstream.layer = next_layer;
                queue.push(downstream);
            }
        }
    }

    // COORDINATES
    HashMap{int, int} layer_counts;
    topo.nodes.@each(; String name, Node* node) {
        int current_layer = node.layer;
        int h_idx = layer_counts.get(current_layer) ?? 0;
        node.y = current_layer * LAYER_HEIGHT; 
        node.x = h_idx * (NODE_WIDTH * 2); 
        layer_counts.set(current_layer, h_idx + 1);
    };
}


