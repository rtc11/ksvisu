module ksvisu;

import std::io;
import std::collections::map;
import std::collections::list;
import ksvisu::color;

faultdef ILLEGAL_ARG, NOT_FOUND;

alias NodeList = List{Node*};
alias TopicNodeMap = HashMap{String, NodeList};

struct Options
{
    bool show_all;
    bool diff;
    bool gui;
    String topo_path;
    String topo_path_diff;
}

struct Topology {
    HashMap{String, Node*} nodes;
    Allocator alloc;
}

struct Node
{
    int sub_topology;
    int sub_topology_secondary; // for TOPIC nodes that span two sub-topologies (-1 = unused)
    String name;
    Kind kind;
    List{String} topics;
    List{String} stores;
    List{String} downstream;
    List{String} upstream;
    bool is_merged; // true if this node was created by collapsing multiple nodes by topic
    bool is_join;   // true if this node participates in a join (JOINTHIS, JOINOTHER, MERGE, leftjoin)
    // GUI fields
    int layer; 
    float x;
    float y;
    float barycenter;
}

fn bool Node.is_stateful(&self) => self.stores.len() > 0;
fn bool Node.has_topics(&self) => self.topics.len() > 0;
fn bool Node.has_downstreams(&self) => self.downstream.len() > 0;
fn bool Node.has_upstreams(&self) => self.upstream.len() > 0;

enum Kind
{
    SOURCE,
    PROCESSOR,
    SINK,
    TOPIC,
    STORE
}

fn void main(String[] args)
{
    @pool() 
    {
        Options opts = cli(args)!!;

        String[] a = ((String)file::load(tmem, opts.topo_path)!!).tsplit("\n");
        Topology topology = { .alloc = tmem };
        topology.parse_desc(a);
        topology.link_by_topic();
        topology.create_store_nodes();
        topology.tag_join_nodes();

        if (opts.gui) {
            visualize(topology);
            return;
        } 
        switch (opts.diff) {
            case true: 
                String[] b = ((String)file::load(tmem, opts.topo_path_diff)!!).tsplit("\n");
                Topology other = { .alloc = tmem };
                other.parse_desc(b);
                other.link_by_topic();
                other.create_store_nodes();
                other.tag_join_nodes();
                topology.diff(other, opts);   
            case false: 
                topology.print(opts);   
        }
    };
}

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

fn void Topology.diff(&self, Topology other, Options opts)
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
    };
    name_len_max += 5;

    Node*[] nodes = self.nodes.tvalues();
    Node*[] other_nodes = other.nodes.tvalues();
    foreach(node: other_nodes) {
        if (!self.nodes.has_key(node.name)) continue;
        if (node.is_stateful()) {
            usz padding = name_len_max + 2;
            Node* old_node = self.nodes.get(node.name)!!;
            // Compare all stores; if any differ, skip (handled in the changed section below)
            bool stores_match = (node.stores.len() == old_node.stores.len());
            if (stores_match) {
                for (usz si = 0; si < node.stores.len(); si++) {
                    if (node.stores[si] != old_node.stores[si]) {
                        stores_match = false;
                        break;
                    }
                }
            }
            if (!stores_match) continue;
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
            Node* old_node = self.nodes.get(node.name)!!;
            bool stores_match = (node.stores.len() == old_node.stores.len());
            if (stores_match) {
                for (usz si = 0; si < node.stores.len(); si++) {
                    if (node.stores[si] != old_node.stores[si]) {
                        stores_match = false;
                        break;
                    }
                }
            }
            if (stores_match) continue;
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
            if (try id = parts[1].to_int()) {
                self.parse_sub(id, input, &offset);
            } else {
                // todo:   Sub-topology: 0 for global store (will not generate tasks)
                self.parse_sub(-1, input, &offset);
            }
        }
    }
}

fn void Topology.parse_sub(&self, int id, String[] input, int* offset)
{
    // io::printfn("SUB TOPOLOGY %s", id);

    Node* node = null;

    while (*offset < input.len) {
        String line = input[*offset];
        if (line.contains("Sub-topology:")) break;
        (*offset)++;
        if (!line) break;

        switch {
            case line.contains("Source: "):
                if (node != null && node.name) self.nodes.@get_or_set(node.name, node);
                node = allocator::new(self.alloc, Node, {
                    .sub_topology = id,
                    .sub_topology_secondary = -1,
                    .kind = SOURCE,
                    .name = line.trim().tsplit(" ")[1].trim(),
                    .layer = -1,
                });
                usz a = line.index_of_char('[')!! + 1;
                usz b = line.index_of_char(']')!! - 1;
                String[] topics = line[a..b].tsplit(",");
                foreach(topic: topics) {
                    String topic_trim = topic.trim();
                    if (!topic_trim) continue;
                    node.topics.push(topic_trim);
                }
            case line.contains("Processor: "):
                if (node != null && node.name) self.nodes.@get_or_set(node.name, node);
                node = allocator::new(self.alloc, Node, {
                    .sub_topology = id,
                    .sub_topology_secondary = -1,
                    .kind = PROCESSOR,
                    .name = line.trim().tsplit(" ")[1].trim(),
                    .layer = -1,
                });
                usz a = line.index_of_char('[')!! + 1;
                usz b = line.index_of_char(']')!! - 1;
                String[] stores = line[a..b].tsplit(",");
                foreach(store: stores) {
                    String store_trim = store.trim();
                    if (!store_trim) continue;
                    node.stores.push(store_trim);
                }
            case line.contains("Sink: "):
                if (node != null && node.name) self.nodes.@get_or_set(node.name, node);
                node = allocator::new(self.alloc, Node, {
                    .sub_topology = id,
                    .sub_topology_secondary = -1,
                    .kind = SINK,
                    .name = line.trim().tsplit(" ")[1].trim(),
                    .layer = -1,
                });
                usz a = line.index_of_char('(')!! + 1;
                usz b = line.index_of_char(')')!! - 1;
                String skew = "topic: ";
                String topic = line[a+skew.len..b];
                if (topic) node.topics.push(topic);
            case line.contains("-->"):
                String dstream = line.tsplit("--> ")[1].trim();
                if (dstream == "none") continue;
                foreach (ds : dstream.tsplit(",", skip_empty:true)) {
                    node.downstream.push(ds.trim());
                }
            case line.contains("<--"):
                String ustream = line.tsplit("<-- ")[1].trim();
                if (ustream == "none") continue;
                foreach (us : ustream.tsplit(",", skip_empty:true)) {
                    node.upstream.push(us.trim());
                }
        }
    }

    if (node != null && node.name) self.nodes.@get_or_set(node.name, node);

}

fn void Topology.link_by_topic(&self)
{
    // Build topic -> sinks and topic -> sources maps
    TopicNodeMap sinks_by_topic;
    TopicNodeMap sources_by_topic;

    self.nodes.@each(; String name, Node* node) {
        if (node.kind == SINK) {
            foreach (topic : node.topics) {
                if (!sinks_by_topic.has_key(topic)) {
                    NodeList l;
                    sinks_by_topic.set(topic, l);
                }
                sinks_by_topic.get_ref(topic)!!.push(node);
            }
        } else if (node.kind == SOURCE) {
            foreach (topic : node.topics) {
                if (!sources_by_topic.has_key(topic)) {
                    NodeList l;
                    sources_by_topic.set(topic, l);
                }
                sources_by_topic.get_ref(topic)!!.push(node);
            }
        }
    };

    // For each topic present in both maps, collapse SINK/SOURCE pairs into a TOPIC node
    sinks_by_topic.@each(; String topic, NodeList sink_nodes) {
        if (sources_by_topic.has_key(topic)) {
            NodeList source_nodes = sources_by_topic.get(topic)!!;
            foreach (sink : sink_nodes) {
                foreach (source : source_nodes) {
                    if (sink.sub_topology == source.sub_topology) continue;
                    self.collapse_sink_source(sink, source, topic);
                }
            }
        }
    };
}

// Collapse a cross-sub-topology SINK->SOURCE pair into a single TOPIC node.
// The TOPIC node inherits the SINK's upstream and the SOURCE's downstream,
// making the graph continuous across sub-topology boundaries.
fn void Topology.collapse_sink_source(&self, Node* sink, Node* source, String topic)
{
    // Create the merged TOPIC node
    Node* topic_node = allocator::new(self.alloc, Node, {
        .sub_topology = sink.sub_topology,
        .sub_topology_secondary = source.sub_topology,
        .kind = TOPIC,
        .name = topic,
        .layer = -1,
    });
    topic_node.topics.push(topic);

    // Inherit SINK's upstream connections
    foreach (us_name : sink.upstream) {
        topic_node.upstream.push(us_name);
        // Rewrite the upstream node's downstream: replace sink name with topic name
        Node*? us_node = self.nodes.get(us_name);
        if (catch us_node) continue;
        self.replace_in_list(&us_node.downstream, sink.name, topic);
    }

    // Inherit SOURCE's downstream connections
    foreach (ds_name : source.downstream) {
        topic_node.downstream.push(ds_name);
        // Rewrite the downstream node's upstream: replace source name with topic name
        Node*? ds_node = self.nodes.get(ds_name);
        if (catch ds_node) continue;
        self.replace_in_list(&ds_node.upstream, source.name, topic);
    }

    // Remove original SINK and SOURCE nodes from topology
    self.nodes.remove(sink.name);
    self.nodes.remove(source.name);

    // Add the merged TOPIC node
    self.nodes.set(topic, topic_node);
}

fn void Topology.replace_in_list(&self, List{String}* list, String old_val, String new_val)
{
    for (usz i = 0; i < list.len(); i++) {
        if ((*list)[i] == old_val) {
            (*list)[i] = new_val;
            return;
        }
    }
}

// Build a shadow topology where SINK nodes sharing the same destination topic
// are collapsed into a single node, and SOURCE nodes sharing the same source
// topic are collapsed into a single node. The original topology is not mutated.
fn Topology Topology.build_collapsed(&self)
{
    Topology collapsed = { .alloc = self.alloc };

    // Step 1: Group SINK and SOURCE nodes by topic, copy others directly
    TopicNodeMap sinks_by_topic;
    TopicNodeMap sources_by_topic;

    self.nodes.@each(; String name, Node* node) {
        switch (node.kind) {
            case SINK:
                if (node.has_topics()) {
                    String topic = node.topics[0];
                    if (!sinks_by_topic.has_key(topic)) {
                        NodeList l;
                        sinks_by_topic.set(topic, l);
                    }
                    sinks_by_topic.get_ref(topic)!!.push(node);
                } else {
                    collapsed.nodes.set(name, node);
                }
            case SOURCE:
                if (node.has_topics()) {
                    // Group by each topic the source reads from
                    foreach (topic : node.topics) {
                        if (!sources_by_topic.has_key(topic)) {
                            NodeList l;
                            sources_by_topic.set(topic, l);
                        }
                        sources_by_topic.get_ref(topic)!!.push(node);
                    }
                } else {
                    collapsed.nodes.set(name, node);
                }
            default:
                collapsed.nodes.set(name, node);
        }
    };

    // Step 2: Merge SINK groups
    sinks_by_topic.@each(; String topic, NodeList sink_nodes) {
        if (sink_nodes.len() <= 1) {
            // Single sink -- copy as-is
            foreach (sink : sink_nodes) {
                collapsed.nodes.set(sink.name, sink);
            }
        } else {
            // Multiple sinks share this topic -- merge them
            String merged_name = string::tformat("SINK:%s", topic);
            Node* merged = allocator::new(self.alloc, Node, {
                .sub_topology = sink_nodes[0].sub_topology,
                .sub_topology_secondary = -1,
                .kind = SINK,
                .name = merged_name,
                .layer = -1,
                .is_merged = true,
            });
            merged.topics.push(topic);

            // Collect unique upstream names from all sinks
            foreach (sink : sink_nodes) {
                foreach (us_name : sink.upstream) {
                    if (!list_contains(&merged.upstream, us_name)) {
                        merged.upstream.push(us_name);
                    }
                }
            }

            collapsed.nodes.set(merged_name, merged);

            // Rewrite upstream nodes' downstream lists
            foreach (us_name : merged.upstream) {
                Node*? us_node = self.nodes.get(us_name);
                if (catch us_node) continue;
                // Replace all original sink names with the merged name
                for (usz i = 0; i < us_node.downstream.len(); i++) {
                    foreach (sink : sink_nodes) {
                        if (us_node.downstream[i] == sink.name) {
                            us_node.downstream[i] = merged_name;
                        }
                    }
                }
            }
        }
    };

    // Step 3: Merge SOURCE groups
    // First, track which source nodes have already been placed (a source with
    // multiple topics might appear in several groups; we only merge it once).
    HashMap{String, bool} placed_sources;

    sources_by_topic.@each(; String topic, NodeList source_nodes) {
        if (source_nodes.len() <= 1) {
            // Single source for this topic -- copy as-is (if not already placed)
            foreach (src : source_nodes) {
                if (!placed_sources.has_key(src.name)) {
                    collapsed.nodes.set(src.name, src);
                    placed_sources.set(src.name, true);
                }
            }
        } else {
            // Multiple sources share this topic -- merge them
            String merged_name = string::tformat("SOURCE:%s", topic);

            if (!collapsed.nodes.has_key(merged_name)) {
                Node* merged = allocator::new(self.alloc, Node, {
                    .sub_topology = source_nodes[0].sub_topology,
                    .sub_topology_secondary = -1,
                    .kind = SOURCE,
                    .name = merged_name,
                    .layer = -1,
                    .is_merged = true,
                });
                merged.topics.push(topic);

                // Collect unique downstream names from all sources
                foreach (src : source_nodes) {
                    foreach (ds_name : src.downstream) {
                        if (!list_contains(&merged.downstream, ds_name)) {
                            merged.downstream.push(ds_name);
                        }
                    }
                    placed_sources.set(src.name, true);
                }

                collapsed.nodes.set(merged_name, merged);

                // Rewrite downstream nodes' upstream lists
                foreach (ds_name : merged.downstream) {
                    Node*? ds_node = self.nodes.get(ds_name);
                    if (catch ds_node) continue;
                    for (usz i = 0; i < ds_node.upstream.len(); i++) {
                        foreach (src : source_nodes) {
                            if (ds_node.upstream[i] == src.name) {
                                ds_node.upstream[i] = merged_name;
                            }
                        }
                    }
                }
            }
        }
    };

    return collapsed;
}

// Undo the downstream/upstream rewrites done by build_collapsed so the
// original topology's adjacency lists are clean for next rebuild.
fn void Topology.restore_edges(&self, Topology* collapsed)
{
    // Restore downstream lists: for each merged SINK, replace the merged name
    // back with the original sink names in upstream nodes' downstream lists.
    collapsed.nodes.@each(; String name, Node* merged) {
        if (merged.is_merged) {
            if (merged.kind == SINK) {
                foreach (us_name : merged.upstream) {
                    Node*? us_node = self.nodes.get(us_name);
                    if (catch us_node) continue;
                    // Remove all occurrences of merged name, re-add original sink names
                    List{String} new_ds;
                    foreach (ds : us_node.downstream) {
                        if (ds == merged.name) {
                            // Find original sinks that had this upstream
                            self.nodes.@each(; String orig_name, Node* orig) {
                                if (orig.kind == SINK && orig.has_topics() && orig.topics[0] == merged.topics[0]) {
                                    if (!list_contains(&new_ds, orig.name)) {
                                        new_ds.push(orig.name);
                                    }
                                }
                            };
                        } else {
                            if (!list_contains(&new_ds, ds)) {
                                new_ds.push(ds);
                            }
                        }
                    }
                    us_node.downstream = new_ds;
                }
            } else if (merged.kind == SOURCE) {
                foreach (ds_name : merged.downstream) {
                    Node*? ds_node = self.nodes.get(ds_name);
                    if (catch ds_node) continue;
                    List{String} new_us;
                    foreach (us : ds_node.upstream) {
                        if (us == merged.name) {
                            self.nodes.@each(; String orig_name, Node* orig) {
                                if (orig.kind == SOURCE && orig.has_topics()) {
                                    foreach (t : orig.topics) {
                                        if (t == merged.topics[0]) {
                                            if (!list_contains(&new_us, orig.name)) {
                                                new_us.push(orig.name);
                                            }
                                        }
                                    }
                                }
                            };
                        } else {
                            if (!list_contains(&new_us, us)) {
                                new_us.push(us);
                            }
                        }
                    }
                    ds_node.upstream = new_us;
                }
            }
        }
    };
}

fn bool list_contains(List{String}* list, String value)
{
    foreach (item : *list) {
        if (item == value) return true;
    }
    return false;
}

// Create synthetic STORE nodes for each unique state store referenced by processors.
// Each STORE node is connected bidirectionally to every processor that references it.
fn void Topology.create_store_nodes(&self)
{
    // Collect unique store names and the processors that reference each store.
    HashMap{String, NodeList} store_to_processors;

    self.nodes.@each(; String name, Node* node) {
        if (node.kind != PROCESSOR) return;
        foreach (store_name : node.stores) {
            if (!store_to_processors.has_key(store_name)) {
                NodeList l;
                store_to_processors.set(store_name, l);
            }
            store_to_processors.get_ref(store_name)!!.push(node);
        }
    };

    // For each unique store, create a STORE node and wire edges.
    store_to_processors.@each(; String store_name, NodeList processors) {
        // Only create store nodes for stores referenced by at least one processor
        if (processors.len() == 0) return;

        // Use the sub-topology of the first referencing processor
        int sub_topo = processors[0].sub_topology;

        Node* store_node = allocator::new(self.alloc, Node, {
            .sub_topology = sub_topo,
            .sub_topology_secondary = -1,
            .kind = STORE,
            .name = store_name,
            .layer = -1,
        });

        // Connect store node <-> each referencing processor
        foreach (proc : processors) {
            // Processor -> Store (processor uses this store)
            proc.downstream.push(store_name);
            store_node.upstream.push(proc.name);
        }

        self.nodes.set(store_name, store_node);
    };
}

// Tag nodes whose names indicate they participate in a Kafka Streams join.
// This includes KTABLE-JOINTHIS, KTABLE-JOINOTHER, KTABLE-MERGE, KSTREAM-MERGE,
// and any processor with "leftjoin" or "outerjoin" in the name.
fn void Topology.tag_join_nodes(&self)
{
    self.nodes.@each(; String name, Node* node) {
        if (node.kind != PROCESSOR) return;

        if (name.contains("JOINTHIS") ||
            name.contains("JOINOTHER") ||
            name.contains("KTABLE-MERGE") ||
            name.contains("KSTREAM-MERGE") ||
            name.contains("leftjoin") ||
            name.contains("outerjoin")) {
            node.is_join = true;
        }
    };
}

