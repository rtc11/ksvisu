module ksvisu;

import std::io;
import std::io::path;
import std::collections::map;
import std::collections::list;

// Variable map: resolves Kotlin variable references like "Topics.dp" -> "teamdagpenger.utbetaling.v1"
alias VarMap = HashMap{String, String};

// Add a source ref to the kotlin index under the given key.
fn void index_add(KotlinIndex* index, String key, String file, int line_num, String content) {
    if (!key || key.len == 0) return;
    if (!index.has_key(key)) {
        SourceRefList l;
        index.set(key, l);
    }
    SourceRefList* list = index.get_ref(key)!!;
    SourceRef ref = { .file = file, .line = line_num, .content = content };
    list.push(ref);
}

// Extract a quoted string literal from a line, starting search from `from` position.
// Returns the content between the first pair of double quotes found at or after `from`.
fn String extract_quoted(String line, usz from) {
    usz? start_idx = line.index_of_char_from('"', from);
    if (catch start_idx) return "";
    usz start = start_idx;
    usz? end_idx = line.index_of_char_from('"', start + 1);
    if (catch end_idx) return "";
    usz end = end_idx;
    if (end <= start + 1) return "";
    return line[start + 1..end - 1];
}

// Extract the last quoted string literal from a line.
fn String extract_last_quoted(String line) {
    String best = "";
    usz pos = 0;
    while (pos < line.len) {
        usz? start_idx = line.index_of_char_from('"', pos);
        if (catch start_idx) break;
        usz start = start_idx;
        usz? end_idx = line.index_of_char_from('"', start + 1);
        if (catch end_idx) break;
        usz end = end_idx;
        if (end > start + 1) {
            best = line[start + 1..end - 1];
        }
        pos = end + 1;
    }
    return best;
}

// Resolve a Kotlin string template like "from-${Topics.dp.name}" using the variable map.
// Handles simple ${X.Y.name} patterns where X.Y maps to a known value.
fn String resolve_template(String tmpl, VarMap* vars) {
    usz? dollar_idx = tmpl.index_of("${");
    if (catch dollar_idx) return tmpl; // no template, return as-is
    usz dollar = dollar_idx;

    usz? close_idx = tmpl.index_of_char_from('}', dollar);
    if (catch close_idx) return tmpl;
    usz close = close_idx;

    // Extract the expression inside ${}
    String expr = tmpl[dollar + 2..close - 1];

    // Strip trailing ".name" if present (e.g., "Topics.dp.name" -> "Topics.dp")
    String var_ref = expr;
    if (var_ref.ends_with(".name")) {
        var_ref = var_ref[..var_ref.len - 6];
    }

    // Look up the variable
    String? resolved = vars.get(var_ref);
    if (catch resolved) return ""; // can't resolve
    String val = resolved;

    // Build the resolved string: prefix + resolved value + suffix
    String prefix = "";
    if (dollar > 0) {
        prefix = tmpl[..dollar - 1];
    }
    String suffix = "";
    if (close + 1 < tmpl.len) {
        suffix = tmpl[close + 1..];
    }

    return string::tformat("%s%s%s", prefix, val, suffix);
}

// Find the first occurrence of `needle` in `line` at or after position `from`.
fn usz find_from(String line, String needle, usz from) {
    if (from + needle.len > line.len) return line.len; // not found sentinel
    for (usz i = from; i + needle.len <= line.len; i++) {
        if (line[i..i + needle.len - 1] == needle) return i;
    }
    return line.len; // not found sentinel
}

// Extract the variable reference from a pattern like "Topics.dp" from "consume(Topics.dp)"
// starting search from `from` position. Looks for "Topics." or "Tables." followed by
// an identifier (until closing paren, comma, or end).
fn String extract_var_ref(String line, usz from, String prefix) {
    usz start = find_from(line, prefix, from);
    if (start >= line.len) return "";

    usz ref_end = start;
    // Scan forward to find end of identifier: stop at ')', ',', ' ', or end of line
    while (ref_end < line.len) {
        char c = line[ref_end];
        if (c == ')' || c == ',' || c == ' ' || c == '\t') break;
        ref_end++;
    }
    if (ref_end <= start) return "";
    return line[start..ref_end - 1];
}

// Strip trailing characters from a string (e.g., trailing ')' or ',').
fn String strip_trailing(String s, char c) {
    String result = s;
    while (result.len > 0 && result[result.len - 1] == c) {
        result = result[..result.len - 2];
    }
    return result;
}

// Try to resolve a variable reference (e.g., "Topics.dp") from the vars map.
// Returns empty string if not found.
fn String var_resolve(VarMap* vars, String var_ref) {
    if (!var_ref || var_ref.len == 0) return "";
    String? result = vars.get(var_ref);
    if (catch result) return "";
    return result;
}

// Scan all .kt files under the given directory and build a KotlinIndex.
// Two-pass approach:
//   Pass 1: Collect Topic/Table variable declarations (val X = Topic("name", ...) etc.)
//   Pass 2: Index all DSL calls that produce named topology elements
fn KotlinIndex scan_kotlin_sources(String dir_path) {
    KotlinIndex index;
    VarMap vars;

    // Collect all .kt files recursively
    List{String} kt_files;
    kt_files.tinit();

    Path? root_result = path::new(tmem, dir_path);
    if (catch root_result) {
        io::printfn("Warning: could not open Kotlin source directory '%s'", dir_path);
        return index;
    }
    Path root_path = root_result;
    collect_kt_files(root_path, &kt_files, dir_path);

    if (kt_files.len() == 0) {
        io::printfn("Warning: no .kt files found in '%s'", dir_path);
        return index;
    }

    io::printfn("Scanning %d Kotlin files...", kt_files.len());

    // Pass 1: Collect variable declarations
    foreach (file_path : kt_files) {
        String? file_result = (String)file::load(tmem, file_path);
        if (catch file_result) continue;
        String file_content = file_result;
        String[] lines = file_content.tsplit("\n");

        String current_object = ""; // track "object Topics" etc.

        foreach (i, line : lines) {
            String trimmed = line.trim();

            // Track object scope (e.g., "object Topics {")
            if (trimmed.starts_with("object ")) {
                String after = trimmed[7..].trim();
                String[] parts = after.tsplit(" ");
                if (parts.len > 0 && parts[0].len > 0) {
                    current_object = parts[0];
                    if (current_object.ends_with("{") || current_object.ends_with(":")) {
                        current_object = current_object[..current_object.len - 2];
                    }
                }
            }

            // val dp = Topic("teamdagpenger.utbetaling.v1", ...)
            if (trimmed.starts_with("val ") && trimmed.contains("Topic(\"")) {
                String topic_name = extract_quoted(trimmed, 0);
                if (topic_name.len > 0) {
                    String after_val = trimmed[4..].trim();
                    String[] parts = after_val.tsplit(" ");
                    if (parts.len > 0) {
                        String var_name = parts[0];
                        if (current_object.len > 0) {
                            String full_ref = string::tformat("%s.%s", current_object, var_name);
                            vars.set(full_ref, topic_name);
                        }
                        vars.set(var_name, topic_name);
                    }
                }
            }

            // val utbetalinger = Table(Topics.utbetalinger, stateStoreName = "...")
            if (trimmed.starts_with("val ") && trimmed.contains("Table(")) {
                String after_val = trimmed[4..].trim();
                String[] parts = after_val.tsplit(" ");
                if (parts.len > 0) {
                    String var_name = parts[0];

                    String topic_ref = extract_var_ref(trimmed, 0, "Topics.");
                    topic_ref = strip_trailing(topic_ref, ')');
                    topic_ref = strip_trailing(topic_ref, ',');
                    String tn = var_resolve(&vars, topic_ref);

                    if (tn.len > 0) {
                        if (current_object.len > 0) {
                            String full_ref = string::tformat("%s.%s", current_object, var_name);
                            vars.set(full_ref, tn);
                        }
                        vars.set(var_name, tn);

                        String rel_file = make_relative(file_path, dir_path);
                        if (trimmed.contains("stateStoreName")) {
                            String store_tmpl = extract_last_quoted(trimmed);
                            if (store_tmpl.len > 0) {
                                String resolved = resolve_template(store_tmpl, &vars);
                                if (resolved.len > 0) {
                                    index_add(&index, resolved, rel_file, (int)i + 1, trimmed);
                                }
                            }
                        } else {
                            String default_store = string::tformat("%s-state-store", tn);
                            index_add(&index, default_store, rel_file, (int)i + 1, trimmed);
                        }
                    }
                }
            }
        }
    }

    // Pass 2: Index DSL calls
    foreach (file_path : kt_files) {
        String? file_result = (String)file::load(tmem, file_path);
        if (catch file_result) continue;
        String file_content = file_result;
        String[] lines = file_content.tsplit("\n");
        String rel_file = make_relative(file_path, dir_path);

        foreach (i, line : lines) {
            String trimmed = line.trim();
            int line_num = (int)i + 1;

            // Topic("name", ...) -- index the topic name
            if (trimmed.contains("Topic(\"")) {
                String topic_name = extract_quoted(trimmed, 0);
                if (topic_name.len > 0) {
                    index_add(&index, topic_name, rel_file, line_num, trimmed);
                }
            }

            // consume(Topics.X) or consume(Tables.X)
            if (trimmed.contains("consume(Topics.") || trimmed.contains("consume(Tables.")) {
                String pfx = trimmed.contains("consume(Topics.") ? "Topics." : "Tables.";
                String var_ref = extract_var_ref(trimmed, 0, pfx);
                var_ref = strip_trailing(var_ref, ')');
                String val = var_resolve(&vars, var_ref);
                if (val.len > 0) {
                    String consume_key = string::tformat("consume-%s", val);
                    index_add(&index, consume_key, rel_file, line_num, trimmed);
                    index_add(&index, val, rel_file, line_num, trimmed);
                }
            }

            // .produce(Topics.X)
            if (trimmed.contains("produce(Topics.")) {
                String var_ref = extract_var_ref(trimmed, 0, "Topics.");
                var_ref = strip_trailing(var_ref, ')');
                String val = var_resolve(&vars, var_ref);
                if (val.len > 0) {
                    index_add(&index, val, rel_file, line_num, trimmed);
                }
            }

            // .leftJoin(..., "name") -- the last quoted string is the named operator
            if (trimmed.contains(".leftJoin(")) {
                String name = extract_last_quoted(trimmed);
                if (name.len > 0) {
                    index_add(&index, name, rel_file, line_num, trimmed);
                }
            }

            // .repartition(Topics.X, N, "from-${Topics.X.name}")
            if (trimmed.contains(".repartition(")) {
                String tmpl = extract_last_quoted(trimmed);
                if (tmpl.len > 0) {
                    String resolved = resolve_template(tmpl, &vars);
                    if (resolved.len > 0) {
                        index_add(&index, resolved, rel_file, line_num, trimmed);
                    }
                }
                String var_ref = extract_var_ref(trimmed, 0, "Topics.");
                var_ref = strip_trailing(var_ref, ')');
                var_ref = strip_trailing(var_ref, ',');
                String val = var_resolve(&vars, var_ref);
                if (val.len > 0) {
                    index_add(&index, val, rel_file, line_num, trimmed);
                }
            }

            // .merge(consume(Topics.X))
            if (trimmed.contains(".merge(consume(Topics.")) {
                String var_ref = extract_var_ref(trimmed, 0, "Topics.");
                var_ref = strip_trailing(var_ref, ')');
                String val = var_resolve(&vars, var_ref);
                if (val.len > 0) {
                    index_add(&index, val, rel_file, line_num, trimmed);
                }
            }

            // globalKTable(Tables.X)
            if (trimmed.contains("globalKTable(Tables.")) {
                String var_ref = extract_var_ref(trimmed, 0, "Tables.");
                var_ref = strip_trailing(var_ref, ')');
                String val = var_resolve(&vars, var_ref);
                if (val.len > 0) {
                    index_add(&index, val, rel_file, line_num, trimmed);
                }
            }

            // Store(Tables.X)
            if (trimmed.contains("Store(Tables.")) {
                String var_ref = extract_var_ref(trimmed, 0, "Tables.");
                var_ref = strip_trailing(var_ref, ')');
                String val = var_resolve(&vars, var_ref);
                if (val.len > 0) {
                    index_add(&index, val, rel_file, line_num, trimmed);
                }
            }
        }
    }

    io::printfn("Indexed %d Kotlin source references.", index.count);
    return index;
}

// Recursively collect all .kt files under a directory.
fn void collect_kt_files(Path dir, List{String}* result, String base_dir) {
    PathList? all_result = path::ls(tmem, dir);
    if (catch all_result) return;
    PathList all_entries = all_result;
    String dir_str = dir.str_view();

    foreach (entry : all_entries) {
        String entry_name = entry.str_view();
        // Build the full path by joining dir + entry name
        String full_path = string::tformat("%s/%s", dir_str, entry_name);

        if (entry_name.ends_with(".kt")) {
            result.push(full_path);
        } else {
            // Skip known non-directory file extensions
            if (entry_name.ends_with(".xml") || entry_name.ends_with(".kts") ||
                entry_name.ends_with(".yml") || entry_name.ends_with(".yaml") ||
                entry_name.ends_with(".json") || entry_name.ends_with(".properties") ||
                entry_name.ends_with(".txt") || entry_name.ends_with(".md") ||
                entry_name.ends_with(".gradle") || entry_name.ends_with(".java") ||
                entry_name.ends_with(".gitkeep") || entry_name.ends_with(".gitignore") ||
                entry_name.starts_with(".")) {
                continue;
            }
            // Try to recurse into it as a subdirectory
            Path? sub_result = path::new(tmem, full_path);
            if (catch sub_result) continue;
            Path sub_path = sub_result;
            collect_kt_files(sub_path, result, base_dir);
        }
    }
}

// Make a file path relative to the base directory for display.
fn String make_relative(String file_path, String base_dir) {
    if (file_path.starts_with(base_dir)) {
        usz start = base_dir.len;
        if (start < file_path.len && file_path[start] == '/') {
            start++;
        }
        return file_path[start..];
    }
    return file_path;
}
