//! MultiDiGraph: a directed multigraph with node and edge payloads.
//!
//! Nodes are identified by `Id` (`[]const u8`, or an integer/enum key) and
//! carry a `NodePayload`. Edges are directed `from -> to`, carry an
//! `EdgePayload`, and form a multigraph: parallel edges and self loops are
//! allowed. Ids, payloads, and any slices they hold are stored by shallow
//! copy and borrowed; the caller keeps the backing memory alive.
//!
//! This is a plain container: structure, adjacency, and induced subgraphs.
//! Ordering (topological sort) lives in `Dag`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn MultiDiGraph(
    comptime Id: type,
    comptime NodePayload: type,
    comptime EdgePayload: type,
) type {
    comptime validateId(Id);

    return struct {
        const Self = @This();

        pub const AddNodeError = Allocator.Error || error{DuplicateNode};
        pub const AddEdgeError = Allocator.Error || error{MissingNode};
        pub const SubgraphError = Allocator.Error || error{ MissingNode, DuplicateNode };

        const NodeMap = if (Id == []const u8)
            std.StringArrayHashMapUnmanaged(Entry)
        else
            std.AutoArrayHashMapUnmanaged(Id, Entry);

        const Entry = struct {
            payload: NodePayload,
            /// Indices into `edges` for which this node is `from` / `to`.
            out: std.ArrayList(u32),
            in: std.ArrayList(u32),
        };

        /// A single directed edge: endpoints plus payload. `from` and `to` are
        /// the graph's stored ids, so they outlive the call that added them.
        pub const Edge = struct {
            from: Id,
            to: Id,
            payload: EdgePayload,
        };

        pub const EdgeIterator = struct {
            graph: *const Self,
            indices: []const u32,
            pos: usize = 0,

            pub fn next(it: *EdgeIterator) ?Edge {
                if (it.pos >= it.indices.len) return null;
                const edge = it.graph.edges.items[it.indices[it.pos]];
                it.pos += 1;
                return edge;
            }
        };

        alloc: Allocator,
        /// Insertion-ordered; node and edge iteration follow insertion order.
        nodes: NodeMap,
        edges: std.ArrayList(Edge),

        pub fn init(alloc: Allocator) Self {
            return .{ .alloc = alloc, .nodes = .empty, .edges = .empty };
        }

        pub fn deinit(self: *Self) void {
            for (self.nodes.values()) |*entry| {
                entry.out.deinit(self.alloc);
                entry.in.deinit(self.alloc);
            }
            self.nodes.deinit(self.alloc);
            self.edges.deinit(self.alloc);
            self.* = undefined;
        }

        /// Stores a shallow copy of `payload` under `id`. Fails with
        /// `error.DuplicateNode` if `id` already exists.
        pub fn addNode(self: *Self, id: Id, payload: NodePayload) AddNodeError!void {
            const gop = try self.nodes.getOrPut(self.alloc, id);
            if (gop.found_existing) return error.DuplicateNode;
            gop.value_ptr.* = .{ .payload = payload, .out = .empty, .in = .empty };
        }

        /// Adds a directed edge `from -> to` carrying `payload`. Parallel edges
        /// and self loops are allowed. Fails with `error.MissingNode` if either
        /// endpoint is absent.
        pub fn addEdge(self: *Self, from: Id, to: Id, payload: EdgePayload) AddEdgeError!void {
            const from_idx = self.nodes.getIndex(from) orelse return error.MissingNode;
            const to_idx = self.nodes.getIndex(to) orelse return error.MissingNode;
            const keys = self.nodes.keys();

            const edge_index: u32 = @intCast(self.edges.items.len);
            try self.edges.append(self.alloc, .{
                .from = keys[from_idx],
                .to = keys[to_idx],
                .payload = payload,
            });
            errdefer _ = self.edges.pop();

            const values = self.nodes.values();
            try values[from_idx].out.append(self.alloc, edge_index);
            errdefer _ = values[from_idx].out.pop();
            try values[to_idx].in.append(self.alloc, edge_index);
        }

        pub fn hasNode(self: *const Self, id: Id) bool {
            return self.nodes.contains(id);
        }

        /// Shallow copy of the payload stored under `id`, or null if absent.
        pub fn nodePayload(self: *const Self, id: Id) ?NodePayload {
            const idx = self.nodes.getIndex(id) orelse return null;
            return self.nodes.values()[idx].payload;
        }

        /// Node ids in insertion order. Borrowed; valid until the next mutation.
        pub fn nodeIds(self: *const Self) []const Id {
            return self.nodes.keys();
        }

        pub fn nodeCount(self: *const Self) usize {
            return self.nodes.count();
        }

        pub fn edgeCount(self: *const Self) usize {
            return self.edges.items.len;
        }

        /// Outgoing edges of `id` in insertion order; empty if `id` is absent.
        pub fn outEdges(self: *const Self, id: Id) EdgeIterator {
            return .{ .graph = self, .indices = self.adjacency(id, .out) };
        }

        /// Incoming edges of `id` in insertion order; empty if `id` is absent.
        pub fn inEdges(self: *const Self, id: Id) EdgeIterator {
            return .{ .graph = self, .indices = self.adjacency(id, .in) };
        }

        fn adjacency(self: *const Self, id: Id, comptime dir: enum { out, in }) []const u32 {
            const idx = self.nodes.getIndex(id) orelse return &.{};
            const entry = self.nodes.values()[idx];
            return switch (dir) {
                .out => entry.out.items,
                .in => entry.in.items,
            };
        }

        /// Builds the subgraph induced by `selected`: those nodes plus every
        /// edge whose endpoints are both selected, in this graph's edge order.
        /// Fails with `error.MissingNode` if a selected id is absent here, or
        /// `error.DuplicateNode` if `selected` repeats an id. The caller owns
        /// the result and must `deinit` it.
        pub fn inducedSubgraph(self: *const Self, selected: []const Id) SubgraphError!Self {
            var result = Self.init(self.alloc);
            errdefer result.deinit();

            for (selected) |id| {
                const idx = self.nodes.getIndex(id) orelse return error.MissingNode;
                try result.addNode(self.nodes.keys()[idx], self.nodes.values()[idx].payload);
            }
            for (self.edges.items) |edge| {
                if (result.hasNode(edge.from) and result.hasNode(edge.to)) {
                    try result.addEdge(edge.from, edge.to, edge.payload);
                }
            }
            return result;
        }
    };
}

fn validateId(comptime Id: type) void {
    if (Id == []const u8) return;
    switch (@typeInfo(Id)) {
        .int, .@"enum" => {},
        else => @compileError("MultiDiGraph Id must be []const u8, an integer, or an enum, got '" ++
            @typeName(Id) ++ "'"),
    }
}

const testing = std.testing;

const Kind = enum { gateway, activity };
const NodeData = struct { type: []const u8, kind: Kind };
const PortEdge = struct { src_port: []const u8, dst_port: []const u8, data_type: []const u8 };
const AppGraph = MultiDiGraph([]const u8, NodeData, PortEdge);

test "addNode rejects duplicate ids" {
    var g = MultiDiGraph([]const u8, void, void).init(testing.allocator);
    defer g.deinit();
    try g.addNode("a", {});
    try testing.expectError(error.DuplicateNode, g.addNode("a", {}));
    try testing.expectEqual(@as(usize, 1), g.nodeCount());
}

test "addEdge rejects missing endpoints" {
    var g = MultiDiGraph([]const u8, void, void).init(testing.allocator);
    defer g.deinit();
    try g.addNode("a", {});
    try testing.expectError(error.MissingNode, g.addEdge("a", "b", {}));
    try testing.expectError(error.MissingNode, g.addEdge("b", "a", {}));
}

test "parallel edges and self loops are allowed" {
    var g = MultiDiGraph([]const u8, void, void).init(testing.allocator);
    defer g.deinit();
    try g.addNode("a", {});
    try g.addNode("b", {});
    try g.addEdge("a", "b", {});
    try g.addEdge("a", "b", {}); // parallel
    try g.addEdge("a", "a", {}); // self loop
    try testing.expectEqual(@as(usize, 3), g.edgeCount());

    var out = g.outEdges("a");
    var out_count: usize = 0;
    while (out.next()) |_| out_count += 1;
    try testing.expectEqual(@as(usize, 3), out_count); // two to b, one self

    var in = g.inEdges("a");
    var in_count: usize = 0;
    while (in.next()) |_| in_count += 1;
    try testing.expectEqual(@as(usize, 1), in_count); // only the self loop
}

test "out/in edges follow insertion order and carry payloads" {
    var g = AppGraph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("gw", .{ .type = "Gw", .kind = .gateway });
    try g.addNode("act", .{ .type = "Act", .kind = .activity });
    try g.addEdge("gw", "act", .{ .src_port = "speed", .dst_port = "speed_in", .data_type = "Speed" });
    try g.addEdge("gw", "act", .{ .src_port = "grade", .dst_port = "grade_in", .data_type = "Grade" });

    var out = g.outEdges("gw");
    const first = out.next().?;
    try testing.expectEqualStrings("gw", first.from);
    try testing.expectEqualStrings("act", first.to);
    try testing.expectEqualStrings("speed", first.payload.src_port);
    try testing.expectEqualStrings("grade", out.next().?.payload.src_port);
    try testing.expectEqual(@as(?AppGraph.Edge, null), out.next());
}

test "nodePayload and hasNode" {
    var g = AppGraph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("gw", .{ .type = "Gw", .kind = .gateway });
    try testing.expect(g.hasNode("gw"));
    try testing.expect(!g.hasNode("missing"));
    try testing.expectEqual(Kind.gateway, g.nodePayload("gw").?.kind);
    try testing.expectEqual(@as(?NodeData, null), g.nodePayload("missing"));
}

test "outEdges and inEdges of an absent node are empty" {
    var g = MultiDiGraph([]const u8, void, void).init(testing.allocator);
    defer g.deinit();
    var out = g.outEdges("nope");
    var in = g.inEdges("nope");
    try testing.expectEqual(@as(?@TypeOf(g).Edge, null), out.next());
    try testing.expectEqual(@as(?@TypeOf(g).Edge, null), in.next());
}

test "integer keys" {
    var g = MultiDiGraph(u32, void, void).init(testing.allocator);
    defer g.deinit();
    try g.addNode(1, {});
    try g.addNode(2, {});
    try g.addEdge(1, 2, {});
    try testing.expectError(error.DuplicateNode, g.addNode(1, {}));
    try testing.expectError(error.MissingNode, g.addEdge(1, 3, {}));
    var out = g.outEdges(1);
    try testing.expectEqual(@as(u32, 2), out.next().?.to);
}

test "inducedSubgraph keeps selected nodes and interior edges in order" {
    var g = AppGraph.init(testing.allocator);
    defer g.deinit();
    try buildSampleGraph(&g);

    var sub = try g.inducedSubgraph(&.{ "comp_a", "comp_b" });
    defer sub.deinit();

    try testing.expectEqual(@as(usize, 2), sub.nodeCount());
    try testing.expectEqual(@as(usize, 1), sub.edgeCount());

    const ids = sub.nodeIds(); // preserves selection/insertion order
    try testing.expectEqual(@as(usize, 2), ids.len);
    try testing.expectEqualStrings("comp_a", ids[0]);
    try testing.expectEqualStrings("comp_b", ids[1]);

    var sub_out = sub.outEdges("comp_a");
    const edge = sub_out.next().?;
    try testing.expectEqualStrings("comp_b", edge.to);
    try testing.expectEqualStrings("acc_cmd_output", edge.payload.src_port);
    try testing.expectEqualStrings("acc_cmd_input", edge.payload.dst_port);
    try testing.expectEqualStrings("AccCmd", edge.payload.data_type);
}

test "inducedSubgraph rejects missing or repeated selections" {
    var g = AppGraph.init(testing.allocator);
    defer g.deinit();
    try buildSampleGraph(&g);
    try testing.expectError(error.MissingNode, g.inducedSubgraph(&.{"ghost"}));
    try testing.expectError(error.DuplicateNode, g.inducedSubgraph(&.{ "comp_a", "comp_a" }));
}

// Integration: the autogen activity dataflow graph. Reproduces the two port
// analyses from the Python `graph_helpers` on top of the library primitives,
// proving MultiDiGraph is sufficient to port that tool's graph layer.

fn buildSampleGraph(g: *AppGraph) !void {
    try g.addNode("ext_in_gw", .{ .type = "ExtInGw", .kind = .gateway });
    try g.addNode("comp_a", .{ .type = "CompA", .kind = .activity });
    try g.addNode("comp_b", .{ .type = "CompB", .kind = .activity });
    try g.addNode("comp_c", .{ .type = "CompC", .kind = .activity });
    try g.addEdge("ext_in_gw", "comp_a", .{ .src_port = "vehicle_speed", .dst_port = "vehicle_speed_input", .data_type = "VehicleSpeed" });
    try g.addEdge("ext_in_gw", "comp_a", .{ .src_port = "target_speed", .dst_port = "target_speed_input", .data_type = "TargetSpeed" });
    try g.addEdge("comp_a", "comp_b", .{ .src_port = "acc_cmd_output", .dst_port = "acc_cmd_input", .data_type = "AccCmd" });
    try g.addEdge("ext_in_gw", "comp_b", .{ .src_port = "road_grade", .dst_port = "road_grade_input", .data_type = "RoadGrade" });
    try g.addEdge("comp_b", "comp_c", .{ .src_port = "torque_req_output", .dst_port = "torque_req_input", .data_type = "TorqueReq" });
    try g.addEdge("ext_in_gw", "comp_c", .{ .src_port = "driver_override", .dst_port = "driver_override_input", .data_type = "DriverOverride" });
}

const Port = struct { data_type: []const u8, port: []const u8 };

fn portsEql(a: Port, b: Port) bool {
    return std.mem.eql(u8, a.data_type, b.data_type) and std.mem.eql(u8, a.port, b.port);
}

fn containsPort(list: []const Port, p: Port) bool {
    for (list) |q| if (portsEql(q, p)) return true;
    return false;
}

/// Distinct (data_type, src_port) outputs of `node` over the full graph.
fn allOutputPorts(full: *const AppGraph, node: []const u8, out: *std.ArrayList(Port)) !void {
    var it = full.outEdges(node);
    while (it.next()) |edge| {
        const p: Port = .{ .data_type = edge.payload.data_type, .port = edge.payload.src_port };
        if (!containsPort(out.items, p)) try out.append(testing.allocator, p);
    }
}

/// Input ports of `node` that exist in `full` but are not wired within `sub`.
fn unconnectedInputPorts(full: *const AppGraph, sub: *const AppGraph, node: []const u8, out: *std.ArrayList(Port)) !void {
    var connected: std.ArrayList([]const u8) = .empty;
    defer connected.deinit(testing.allocator);
    var sub_it = sub.inEdges(node);
    while (sub_it.next()) |edge| try connected.append(testing.allocator, edge.payload.dst_port);

    var it = full.inEdges(node);
    while (it.next()) |edge| {
        const p: Port = .{ .data_type = edge.payload.data_type, .port = edge.payload.dst_port };
        if (containsPort(out.items, p)) continue;
        var wired = false;
        for (connected.items) |c| if (std.mem.eql(u8, c, edge.payload.dst_port)) {
            wired = true;
        };
        if (!wired) try out.append(testing.allocator, p);
    }
}

fn expectPorts(expected: []const Port, actual: []const Port) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try testing.expect(portsEql(e, a));
}

test "autogen port analyses over the activity dataflow graph" {
    var full = AppGraph.init(testing.allocator);
    defer full.deinit();
    try buildSampleGraph(&full);

    var sub = try full.inducedSubgraph(&.{ "comp_a", "comp_b" });
    defer sub.deinit();

    var a_out: std.ArrayList(Port) = .empty;
    defer a_out.deinit(testing.allocator);
    try allOutputPorts(&full, "comp_a", &a_out);
    try expectPorts(&.{.{ .data_type = "AccCmd", .port = "acc_cmd_output" }}, a_out.items);

    var b_out: std.ArrayList(Port) = .empty;
    defer b_out.deinit(testing.allocator);
    try allOutputPorts(&full, "comp_b", &b_out);
    try expectPorts(&.{.{ .data_type = "TorqueReq", .port = "torque_req_output" }}, b_out.items);

    var a_unconnected: std.ArrayList(Port) = .empty;
    defer a_unconnected.deinit(testing.allocator);
    try unconnectedInputPorts(&full, &sub, "comp_a", &a_unconnected);
    try expectPorts(&.{
        .{ .data_type = "VehicleSpeed", .port = "vehicle_speed_input" },
        .{ .data_type = "TargetSpeed", .port = "target_speed_input" },
    }, a_unconnected.items);

    var b_unconnected: std.ArrayList(Port) = .empty;
    defer b_unconnected.deinit(testing.allocator);
    try unconnectedInputPorts(&full, &sub, "comp_b", &b_unconnected);
    // acc_cmd_input is wired inside the subgraph (comp_a -> comp_b); road_grade is not.
    try expectPorts(&.{.{ .data_type = "RoadGrade", .port = "road_grade_input" }}, b_unconnected.items);
}
