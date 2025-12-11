module ksvisu;

import std::io;
import std::collections::map;
import std::collections::list;
import ksvisu::color;

fn void main(String[] args)
{
    @pool() 
    {
        Options opts = cli(args)!!;

        String[] a = ((String)file::load(tmem, opts.topo_path)!!).tsplit("\n");
        Topology topology = { .alloc = tmem };
        topology.parse_desc(a);

        if (opts.gui) {
            visualize(topology);
            return;
        } 
        switch (opts.diff) {
            case true: 
                String[] b = ((String)file::load(tmem, opts.topo_path_diff)!!).tsplit("\n");
                Topology other = { .alloc = tmem };
                other.parse_desc(b);
                topology.diff(other, opts)!!;   
            case false: 
                topology.print(opts);   
        }
    };
}

struct Options
{
    bool show_all;
    bool diff;
    bool gui;
    String topo_path;
    String topo_path_diff;
}

faultdef ILLEGAL_ARG, NOT_FOUND, MULTIPLE_STATE_STORES;

fn Options? cli(String[] args)
{

    if (args.len < 2) {
        io::printfn("Usage: %s <topology.desc> <options>", args[0]);
        return ILLEGAL_ARG?;
    } 
    Options opts = { .topo_path = args[1] };
        if (args.contains("-a")) {
            opts.show_all = true; 
        }
        if (args.contains("-d")) {
            opts.diff = true; 
            opts.topo_path_diff = args[args.index_at("-d")!! + 1]; 
        } 
        if (args.contains("-g")) {
            opts.gui = true;
        }
    return opts;
}

fn void? Topology.diff(&self, Topology other, Options opts)
{
    io::printfn("%s %s %s", "REMOVED".bg(color::RED).fg(color::BLACK), "ADDED".bg(color::GREEN).fg(color::BLACK), "CHANGED".bg(color::PINK).fg(color::BLACK));

    usz name_len_max;
    self.nodes.@each(; String key, Node* node) {
        if (key.len > name_len_max) {
            if (opts.show_all) {
                name_len_max = key.len;
            } else if (node.is_stateful()) {
                name_len_max = key.len;
            }
        }
    };
    other.nodes.@each(; String key, Node* node) {
        if (key.len > name_len_max) {
            if (opts.show_all) {
                name_len_max = key.len;
            } else if (node.is_stateful()) {
                name_len_max = key.len;
            }
        }
        if (key.len > name_len_max) name_len_max = key.len;
    };
    name_len_max += 5;

    Node*[] nodes = self.nodes.tvalues();
    Node*[] other_nodes = other.nodes.tvalues();
    foreach(node: other_nodes) {
        if (!self.nodes.has_key(node.name)) continue;
        if (node.is_stateful()) {
            usz padding = name_len_max + 2;
            if (node.stores.len() != 1) return MULTIPLE_STATE_STORES?;
            String new_store = node.stores.first()!;
            String old_store = self.nodes.get(node.name).stores.first()!;
            if (new_store != old_store) continue;
            io::printfn("%-10s %-*s %s", node.kind, padding, color::gray(node.name), node.stores);
        }
        if (opts.show_all) {
            if (node.has_topics()) io::printfn("%-10s %-*s %s", node.kind, name_len_max + 34, node.name, node.topics);
            if (node.has_downstreams()) io::printfn("%-10s %-*s --> %s", node.kind, name_len_max + 30, node.name, node.downstream);
            if (node.has_upstreams()) io::printfn("%-10s %-*s <-- %s", node.kind, name_len_max + 30, node.name, node.upstream);
        }
    }
    foreach(node: other_nodes) {
        if (!self.nodes.has_key(node.name)) continue;
        if (node.is_stateful()) {
            usz padding = name_len_max + 2;
            if (node.stores.len() != 1) return MULTIPLE_STATE_STORES?;
            String new_store = node.stores.first()!;
            String old_store = self.nodes.get(node.name).stores.first()!;
            if (new_store == old_store) continue;
            io::printfn("%-10s %-*s %s", node.kind, padding - 24, node.name, color::pink(string::tformat("%s", node.stores)));
        }
    }
    foreach(node: nodes) {
        if (other.nodes.has_key(node.name)) continue;
        usz padding = name_len_max;
        if (node.is_stateful()) io::printfn("%-10s %-*s %s", node.kind, padding, color::red(node.name), node.stores);
        if (opts.show_all) {
            if (node.has_topics()) io::printfn("%-10s %-*s %s", node.kind, name_len_max + 34, node.name, node.topics);
            if (node.has_downstreams()) io::printfn("%-10s %-*s --> %s", node.kind, name_len_max + 30, node.name, node.downstream);
            if (node.has_upstreams()) io::printfn("%-10s %-*s <-- %s", node.kind, name_len_max + 30, node.name, node.upstream);
        }
    }
    foreach(node: other_nodes) {
        if (self.nodes.has_key(node.name)) continue;
        usz padding = name_len_max + 2;
        if (node.is_stateful()) io::printfn("%-10s %-*s %s", node.kind, padding, color::green(node.name), node.stores);
        if (opts.show_all) {
            if (node.has_topics()) io::printfn("%-10s %-*s %s", node.kind, name_len_max + 34, node.name, node.topics);
            if (node.has_downstreams()) io::printfn("%-10s %-*s --> %s", node.kind, name_len_max + 30, node.name, node.downstream);
            if (node.has_upstreams()) io::printfn("%-10s %-*s <-- %s", node.kind, name_len_max + 30, node.name, node.upstream);
        }
    }
}

fn bool String[].contains(&self, String needle)
{
    foreach(str: self) if (str == needle) return true;
    return false;
}

fn usz? String[].index_at(&self, String needle)
{
    foreach(i, str: self) if (str == needle) return i;
    return NOT_FOUND?;
}

fn void Topology.print(&self, Options opts)
{
    self.nodes.@each(; String name, Node* node) {
        if (node.is_stateful()) {
            io::printfn("%-10s %-86s %s", node.kind, color::red(node.name), node.stores);
        }
        if (node.has_topics() && opts.show_all) {
            io::printfn("%-10s %-64s %s", node.kind, node.name, node.topics);
        }
        if (node.has_downstreams() && opts.show_all) {
            io::printfn("%-10s %-60s --> %s", node.kind, node.name, node.downstream);
        }
        if (node.has_upstreams() && opts.show_all) {
            io::printfn("%-10s %-60s <-- %s", node.kind, node.name, node.upstream);
        }
    };
}

fn void Topology.parse_desc(&self, String[] input)
{
    int offset = 0;
    while (offset < input.len) {
        String line = input[offset++];
        if (line.contains("Topologies:")) continue; 
        if (line.contains("Sub-topology:")) {
            String[] parts = line.tsplit(":");
            int id = parts[1].to_int()!!;
            self.parse_sub(id, input, &offset);
        }
    }
}

struct Topology {
    HashMap{String, Node*} nodes;
    Allocator alloc;
}

struct Node
{
    int sub_topology;
    String name;
    Kind kind;
    List{String} topics;
    List{String} stores;
    List{String} downstream;
    List{String} upstream;
    int layer; 
    int x;
    int y;
}

enum Kind
{
    SOURCE,
    PROCESSOR,
    SINK
}

fn bool Node.is_stateful(&self) => self.stores.len() > 0;
fn bool Node.has_topics(&self) => self.topics.len() > 0;
fn bool Node.has_downstreams(&self) => self.downstream.len() > 0;
fn bool Node.has_upstreams(&self) => self.upstream.len() > 0;

fn void Topology.parse_sub(&self, int id, String[] input, int* offset)
{
    // io::printfn("SUB TOPOLOGY %s", id);

    Node* node = null;

    while (*offset < input.len) {
        String line = input[*offset];
        (*offset)++;
        if (!line || line.contains("Sub-topology:")) break;

        switch {
            case line.contains("Source: "):
                if (node != null && node.name) self.nodes.@get_or_set(node.name, node);
                node = allocator::new(self.alloc, Node, {
                    .sub_topology = id,
                    .kind = SOURCE,
                    .name = line.trim().tsplit(" ")[1],
                    .layer = -1,
                });
                usz a = line.index_of_char('[')!! + 1;
                usz b = line.index_of_char(']')!! - 1;
                String[] topics = line[a..b].tsplit(",");
                foreach(topic: topics) {
                    if (!topic) continue;
                    node.topics.push(topic);
                }
            case line.contains("Processor: "):
                if (node != null && node.name) self.nodes.@get_or_set(node.name, node);
                node = allocator::new(self.alloc, Node, {
                    .sub_topology = id,
                    .kind = PROCESSOR,
                    .name = line.trim().tsplit(" ")[1],
                    .layer = -1,
                });
                usz a = line.index_of_char('[')!! + 1;
                usz b = line.index_of_char(']')!! - 1;
                String[] stores = line[a..b].tsplit(",");
                foreach(store: stores) {
                    if (!store) continue;
                    node.stores.push(store);
                }
            case line.contains("Sink: "):
                if (node != null && node.name) self.nodes.@get_or_set(node.name, node);
                node = allocator::new(self.alloc, Node, {
                    .sub_topology = id,
                    .kind = SINK,
                    .name = line.trim().tsplit(" ")[1],
                    .layer = -1,
                });
                usz a = line.index_of_char('(')!! + 1;
                usz b = line.index_of_char(')')!! - 1;
                String skew = "topic: ";
                String topic = line[a+skew.len..b];
                if (topic) node.topics.push(topic);
            case line.contains("-->"):
                String dstream = line.tsplit("--> ")[1];
                if (dstream != "none") node.downstream.push(dstream); 
            case line.contains("<--"):
                node.upstream.push(line.tsplit("<-- ")[1]);
        }
    }

    if (node != null && node.name) self.nodes.@get_or_set(node.name, node);

}

