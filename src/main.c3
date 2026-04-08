module ksvisu;

import std::io;
import std::collections::map;
import std::collections::list;

alias NodeList = List{Node*};
alias TopicNodeMap = HashMap{String, NodeList};

// A reference to a Kotlin source location (file + line + content)
struct SourceRef {
    String file;    // relative path to .kt file
    int line;       // 1-indexed line number
    String content; // trimmed line content
}

alias SourceRefList = List{SourceRef};
alias KotlinIndex = HashMap{String, SourceRefList};

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
    List{SourceRef} source_refs; // Kotlin source locations correlated to this node
    // GUI fields
    int layer; 
    float x;
    float y;
    float barycenter;
}

fn bool Node.is_stateful(&self) => self.stores.len() > 0;
fn bool Node.has_topics(&self) => self.topics.len() > 0;

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
    if (args.len < 2) {
        io::printn("Usage: ksvisu <topology.desc> [<kotlin-src-dir>]");
        io::printn("");
        io::printn("Visualize a Kafka Streams topology description file.");
        io::printn("Optionally provide a Kotlin source directory to correlate");
        io::printn("topology nodes with their source code locations.");
        io::printn("");
        io::printn("Example: ./build/ksvisu resources/abetal.desc ~/code/kotlin/myapp/main");
        return;
    }

    @pool() 
    {
        Topology topology = { .alloc = tmem };

        String? content_result = (String)file::load(tmem, args[1]);
        if (catch err = content_result) {
            io::printfn("Error: could not load file '%s' (%s)", args[1], err);
            return;
        }
        String[] a = content_result.tsplit("\n");
        topology.parse_desc(a);
        topology.link_by_topic();
        topology.create_store_nodes();
        topology.tag_join_nodes();

        // Scan Kotlin source files and correlate nodes if a source dir is provided
        KotlinIndex kotlin_index;
        if (args.len >= 3) {
            kotlin_index = scan_kotlin_sources(args[2]);
            if (kotlin_index.count > 0) {
                correlate_nodes(&topology, &kotlin_index);
            }
        }

        visualize(topology);
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

// Add a source ref to a node, avoiding duplicates (same file+line).
fn void Node.add_source_ref(&self, SourceRef ref) {
    foreach (existing : self.source_refs) {
        if (existing.file == ref.file && existing.line == ref.line) return;
    }
    self.source_refs.push(ref);
}

// Try to look up a key in the kotlin index and add all matching refs to the node.
fn void add_refs_for_key(Node* node, KotlinIndex* index, String key) {
    if (!key || key.len == 0) return;
    SourceRefList*? refs = index.get_ref(key);
    if (catch refs) return;
    foreach (ref : *refs) {
        node.add_source_ref(ref);
    }
}

// Correlate topology nodes with Kotlin source references.
// For each node, try to match its name, topics, and stores against the index.
// Also tries stripping known prefixes/suffixes to find the core topic/operator name.
fn void correlate_nodes(Topology* topo, KotlinIndex* index) {
    topo.nodes.@each(; String name, Node* node) {
        // 1. Direct name match
        add_refs_for_key(node, index, name);

        // 2. Topic matches
        foreach (topic : node.topics) {
            add_refs_for_key(node, index, topic);
        }

        // 3. Store matches
        foreach (store : node.stores) {
            add_refs_for_key(node, index, store);
        }

        // 4. Strip known prefixes to get core name
        String core = name;
        if (core.starts_with("consume-")) {
            core = core[8..];
            add_refs_for_key(node, index, core);
        } else if (core.starts_with("ktable-")) {
            core = core[7..];
            add_refs_for_key(node, index, core);
        } else if (core.starts_with("from-")) {
            core = core[5..];
            add_refs_for_key(node, index, core);
        } else if (core.starts_with("SINK:")) {
            core = core[5..];
            add_refs_for_key(node, index, core);
        } else if (core.starts_with("SOURCE:")) {
            core = core[7..];
            add_refs_for_key(node, index, core);
        }

        // 5. Strip repartition suffixes
        if (core.ends_with("-repartition-filter") ||
            core.ends_with("-repartition-source") ||
            core.ends_with("-repartition-sink")) {
            // Find the last "-repartition-" and strip from there
            usz? rp_idx = core.rindex_of("-repartition-");
            if (try idx = rp_idx) {
                String base = core[..idx - 1];
                add_refs_for_key(node, index, base);
            }
        } else if (core.ends_with("-repartition")) {
            usz? rp_idx = core.rindex_of("-repartition");
            if (try idx = rp_idx) {
                String base = core[..idx - 1];
                add_refs_for_key(node, index, base);
            }
        }
    };
}

