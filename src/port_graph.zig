//! PortGraph: a hierarchical directed multigraph with first-class ports.
//!
//! Nodes are identified by `Id` (`[]const u8`, or an integer/enum) and carry a
//! `NodePayload`. Each node declares named, directed ports carrying a
//! `PortPayload`; edges connect a port of one node to a port of another and
//! carry an `EdgePayload`. Parallel edges are allowed (it is a multigraph).
//!
//! Hierarchy is a containment overlay, not nesting: a node may have a `parent`,
//! and a node's `children` are the nodes that name it as parent. The children
//! of a node form its own subgraph (e.g. a component built from subcomponents
//! that talk to each other through ports). Edges may connect siblings or cross
//! one level between a parent and a child (port delegation).
//!
//! Port `Direction` records a port's role (input/output) for consumers such as
//! code generation; it is descriptive and is not enforced when adding edges, so
//! a component's external input port can still drive its children.
//!
//! Like the other types here this is a borrowed container: ids, port names,
//! payloads, and any slices they hold are stored by shallow copy; the caller
//! keeps the backing memory alive. Acyclicity and ordering live in `Dag`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Direction = enum { in, out };

pub fn PortGraph(
    comptime Id: type,
    comptime NodePayload: type,
    comptime PortPayload: type,
    comptime EdgePayload: type,
) type {
    comptime validateId(Id);

    return struct {
        const Self = @This();

        pub const AddNodeError = Allocator.Error || error{ DuplicateNode, MissingParent };
        pub const AddPortError = Allocator.Error || error{ MissingNode, DuplicatePort };
        pub const AddEdgeError = Allocator.Error || error{ MissingNode, MissingPort };

        const NodeMap = if (Id == []const u8)
            std.StringArrayHashMapUnmanaged(Entry)
        else
            std.AutoArrayHashMapUnmanaged(Id, Entry);

        const Port = struct { dir: Direction, payload: PortPayload };
        const PortMap = std.StringArrayHashMapUnmanaged(Port);

        const Entry = struct {
            payload: NodePayload,
            parent: ?Id,
            ports: PortMap,
            /// Indices into `edges` for which this node is `from` / `to`.
            out: std.ArrayList(u32),
            in: std.ArrayList(u32),
        };

        /// A directed edge between two ports, plus payload. Ids and port names
        /// are the graph's stored copies, so they outlive the adding call.
        pub const Edge = struct {
            from: Id,
            from_port: []const u8,
            to: Id,
            to_port: []const u8,
            payload: EdgePayload,
        };

        /// A node's declared port as exposed to callers.
        pub const PortRef = struct { name: []const u8, dir: Direction, payload: PortPayload };

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

        pub const PortIterator = struct {
            names: []const []const u8,
            ports: []const Port,
            pos: usize = 0,

            pub fn next(it: *PortIterator) ?PortRef {
                if (it.pos >= it.names.len) return null;
                const i = it.pos;
                it.pos += 1;
                return .{ .name = it.names[i], .dir = it.ports[i].dir, .payload = it.ports[i].payload };
            }
        };

        pub const ChildIterator = struct {
            graph: *const Self,
            parent: Id,
            pos: usize = 0,

            pub fn next(it: *ChildIterator) ?Id {
                const keys = it.graph.nodes.keys();
                const values = it.graph.nodes.values();
                while (it.pos < keys.len) {
                    const i = it.pos;
                    it.pos += 1;
                    if (values[i].parent) |p| {
                        if (Self.idsEql(p, it.parent)) return keys[i];
                    }
                }
                return null;
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
                entry.ports.deinit(self.alloc);
                entry.out.deinit(self.alloc);
                entry.in.deinit(self.alloc);
            }
            self.nodes.deinit(self.alloc);
            self.edges.deinit(self.alloc);
            self.* = undefined;
        }

        /// Adds a node, optionally contained by `parent`. Fails with
        /// `error.DuplicateNode` if `id` exists, or `error.MissingParent` if
        /// `parent` is given but absent.
        pub fn addNode(self: *Self, id: Id, payload: NodePayload, parent_id: ?Id) AddNodeError!void {
            const parent_idx: ?usize = if (parent_id) |p|
                (self.nodes.getIndex(p) orelse return error.MissingParent)
            else
                null;

            const gop = try self.nodes.getOrPut(self.alloc, id);
            if (gop.found_existing) return error.DuplicateNode;
            gop.value_ptr.* = .{
                .payload = payload,
                .parent = if (parent_idx) |pi| self.nodes.keys()[pi] else null,
                .ports = .empty,
                .out = .empty,
                .in = .empty,
            };
        }

        /// Declares a port on `node`. Fails with `error.MissingNode` if `node`
        /// is absent, or `error.DuplicatePort` if the name is already declared.
        pub fn addPort(self: *Self, node: Id, name: []const u8, dir: Direction, payload: PortPayload) AddPortError!void {
            const idx = self.nodes.getIndex(node) orelse return error.MissingNode;
            const entry = &self.nodes.values()[idx];
            const gop = try entry.ports.getOrPut(self.alloc, name);
            if (gop.found_existing) return error.DuplicatePort;
            gop.value_ptr.* = .{ .dir = dir, .payload = payload };
        }

        /// Adds a directed edge `from.from_port -> to.to_port`. Parallel edges
        /// are allowed. Fails with `error.MissingNode` if an endpoint node is
        /// absent or `error.MissingPort` if a named port is not declared.
        pub fn addEdge(self: *Self, from: Id, from_port: []const u8, to: Id, to_port: []const u8, payload: EdgePayload) AddEdgeError!void {
            const from_idx = self.nodes.getIndex(from) orelse return error.MissingNode;
            const to_idx = self.nodes.getIndex(to) orelse return error.MissingNode;

            const from_entry = &self.nodes.values()[from_idx];
            const to_entry = &self.nodes.values()[to_idx];
            const from_pi = from_entry.ports.getIndex(from_port) orelse return error.MissingPort;
            const to_pi = to_entry.ports.getIndex(to_port) orelse return error.MissingPort;

            const edge_index: u32 = @intCast(self.edges.items.len);
            try self.edges.append(self.alloc, .{
                .from = self.nodes.keys()[from_idx],
                .from_port = from_entry.ports.keys()[from_pi],
                .to = self.nodes.keys()[to_idx],
                .to_port = to_entry.ports.keys()[to_pi],
                .payload = payload,
            });
            errdefer _ = self.edges.pop();

            try from_entry.out.append(self.alloc, edge_index);
            errdefer _ = from_entry.out.pop();
            try to_entry.in.append(self.alloc, edge_index);
        }

        pub fn hasNode(self: *const Self, id: Id) bool {
            return self.nodes.contains(id);
        }

        /// Shallow copy of the payload stored under `id`, or null if absent.
        pub fn nodePayload(self: *const Self, id: Id) ?NodePayload {
            const idx = self.nodes.getIndex(id) orelse return null;
            return self.nodes.values()[idx].payload;
        }

        /// The containing node of `id`, or null if `id` is top-level or absent.
        pub fn parent(self: *const Self, id: Id) ?Id {
            const idx = self.nodes.getIndex(id) orelse return null;
            return self.nodes.values()[idx].parent;
        }

        /// Children of `id` in insertion order; empty if `id` has none or is absent.
        pub fn children(self: *const Self, id: Id) ChildIterator {
            return .{ .graph = self, .parent = id };
        }

        /// Declared ports of `id` in declaration order; empty if `id` is absent.
        pub fn ports(self: *const Self, id: Id) PortIterator {
            const idx = self.nodes.getIndex(id) orelse return .{ .names = &.{}, .ports = &.{} };
            const pm = &self.nodes.values()[idx].ports;
            return .{ .names = pm.keys(), .ports = pm.values() };
        }

        /// The named port of `id`, or null if the node or port is absent.
        pub fn port(self: *const Self, id: Id, name: []const u8) ?PortRef {
            const idx = self.nodes.getIndex(id) orelse return null;
            const pm = &self.nodes.values()[idx].ports;
            const pi = pm.getIndex(name) orelse return null;
            const p = pm.values()[pi];
            return .{ .name = pm.keys()[pi], .dir = p.dir, .payload = p.payload };
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

        fn idsEql(a: Id, b: Id) bool {
            return if (Id == []const u8) std.mem.eql(u8, a, b) else a == b;
        }
    };
}

fn validateId(comptime Id: type) void {
    if (Id == []const u8) return;
    switch (@typeInfo(Id)) {
        .int, .@"enum" => {},
        else => @compileError("PortGraph Id must be []const u8, an integer, or an enum, got '" ++
            @typeName(Id) ++ "'"),
    }
}

const testing = std.testing;

const Kind = enum { component, subcomponent };
const NodeData = struct { type: []const u8, kind: Kind };
const PortType = struct { data_type: []const u8 };
const G = PortGraph([]const u8, NodeData, PortType, void);

test "addNode rejects duplicates and unknown parents" {
    var g = G.init(testing.allocator);
    defer g.deinit();
    try g.addNode("comp_a", .{ .type = "CompA", .kind = .component }, null);
    try testing.expectError(error.DuplicateNode, g.addNode("comp_a", .{ .type = "X", .kind = .component }, null));
    try testing.expectError(error.MissingParent, g.addNode("a_ctrl", .{ .type = "Ctrl", .kind = .subcomponent }, "ghost"));
}

test "addPort rejects missing nodes and duplicate ports" {
    var g = G.init(testing.allocator);
    defer g.deinit();
    try g.addNode("comp_a", .{ .type = "CompA", .kind = .component }, null);
    try testing.expectError(error.MissingNode, g.addPort("ghost", "p", .in, .{ .data_type = "T" }));
    try g.addPort("comp_a", "speed_in", .in, .{ .data_type = "Speed" });
    try testing.expectError(error.DuplicatePort, g.addPort("comp_a", "speed_in", .out, .{ .data_type = "Speed" }));
}

test "addEdge rejects missing nodes and ports" {
    var g = G.init(testing.allocator);
    defer g.deinit();
    try g.addNode("a", .{ .type = "A", .kind = .component }, null);
    try g.addNode("b", .{ .type = "B", .kind = .component }, null);
    try g.addPort("a", "out", .out, .{ .data_type = "T" });
    try testing.expectError(error.MissingNode, g.addEdge("a", "out", "ghost", "in", {}));
    try testing.expectError(error.MissingPort, g.addEdge("a", "out", "b", "in", {})); // b has no "in"
    try g.addPort("b", "in", .in, .{ .data_type = "T" });
    try g.addEdge("a", "out", "b", "in", {});
    try testing.expectEqual(@as(usize, 1), g.edgeCount());
}

test "port direction is descriptive: a parent input may drive a child" {
    var g = G.init(testing.allocator);
    defer g.deinit();
    try g.addNode("comp", .{ .type = "Comp", .kind = .component }, null);
    try g.addNode("child", .{ .type = "Child", .kind = .subcomponent }, "comp");
    try g.addPort("comp", "speed_in", .in, .{ .data_type = "Speed" });
    try g.addPort("child", "speed_in", .in, .{ .data_type = "Speed" });
    // Delegation across the boundary: the component's external input feeds the
    // child's input. This is allowed even though both ports are inputs.
    try g.addEdge("comp", "speed_in", "child", "speed_in", {});
    try testing.expectEqual(@as(usize, 1), g.edgeCount());
}

// Integration: a two-level hierarchical port graph. Each component owns a
// subcomponent pipeline that communicates through ports; components are wired
// to each other at the top level; component boundaries delegate to children.

fn buildSample(g: *G) !void {
    // Top-level components, wired comp_a -> comp_b.
    try g.addNode("comp_a", .{ .type = "CompA", .kind = .component }, null);
    try g.addNode("comp_b", .{ .type = "CompB", .kind = .component }, null);
    try g.addPort("comp_a", "speed_in", .in, .{ .data_type = "Speed" });
    try g.addPort("comp_a", "cmd_out", .out, .{ .data_type = "AccCmd" });
    try g.addPort("comp_b", "cmd_in", .in, .{ .data_type = "AccCmd" });
    try g.addPort("comp_b", "grade_in", .in, .{ .data_type = "RoadGrade" }); // left unwired
    try g.addPort("comp_b", "torque_out", .out, .{ .data_type = "Torque" });
    try g.addEdge("comp_a", "cmd_out", "comp_b", "cmd_in", {}); // edge 0

    // comp_a's internals: a_filter -> a_ctrl (the subcomponent dataflow).
    try g.addNode("a_filter", .{ .type = "Filter", .kind = .subcomponent }, "comp_a");
    try g.addNode("a_ctrl", .{ .type = "Ctrl", .kind = .subcomponent }, "comp_a");
    try g.addPort("a_filter", "speed_in", .in, .{ .data_type = "Speed" });
    try g.addPort("a_filter", "speed_out", .out, .{ .data_type = "Speed" });
    try g.addPort("a_ctrl", "speed_in", .in, .{ .data_type = "Speed" });
    try g.addPort("a_ctrl", "cmd_out", .out, .{ .data_type = "AccCmd" });
    try g.addEdge("a_filter", "speed_out", "a_ctrl", "speed_in", {}); // edge 1
    try g.addEdge("comp_a", "speed_in", "a_filter", "speed_in", {}); // edge 2, delegation in
    try g.addEdge("a_ctrl", "cmd_out", "comp_a", "cmd_out", {}); // edge 3, delegation out
}

fn collectUnconnectedInputs(g: *const G, node: []const u8, out: *std.ArrayList([]const u8)) !void {
    var pit = g.ports(node);
    while (pit.next()) |p| {
        if (p.dir != .in) continue;
        var connected = false;
        var eit = g.inEdges(node);
        while (eit.next()) |e| {
            if (std.mem.eql(u8, e.to_port, p.name)) {
                connected = true;
                break;
            }
        }
        if (!connected) try out.append(testing.allocator, p.name);
    }
}

test "hierarchical port graph: hierarchy, ports, delegation, and analysis" {
    var g = G.init(testing.allocator);
    defer g.deinit();
    try buildSample(&g);

    // Hierarchy: comp_a contains the subcomponent pipeline; comp_b contains none.
    try testing.expectEqual(@as(?[]const u8, null), g.parent("comp_a"));
    try testing.expectEqualStrings("comp_a", g.parent("a_filter").?);
    var ch = g.children("comp_a");
    try testing.expectEqualStrings("a_filter", ch.next().?);
    try testing.expectEqualStrings("a_ctrl", ch.next().?);
    try testing.expect(ch.next() == null);
    var comp_b_children = g.children("comp_b");
    try testing.expect(comp_b_children.next() == null);

    // Ports are first-class and ordered, carrying their role and payload.
    var pit = g.ports("comp_a");
    const p0 = pit.next().?;
    try testing.expectEqualStrings("speed_in", p0.name);
    try testing.expectEqual(Direction.in, p0.dir);
    try testing.expectEqualStrings("Speed", p0.payload.data_type);
    try testing.expectEqual(Direction.out, pit.next().?.dir);
    try testing.expect(pit.next() == null);

    // The subcomponent dataflow edge lives between comp_a's children.
    var f_out = g.outEdges("a_filter");
    const internal = f_out.next().?;
    try testing.expectEqualStrings("a_ctrl", internal.to);
    try testing.expectEqualStrings("speed_in", internal.to_port);

    // comp_a's out-edges: the top-level wire then the inbound delegation.
    var a_out = g.outEdges("comp_a");
    try testing.expectEqualStrings("comp_b", a_out.next().?.to);
    try testing.expectEqualStrings("a_filter", a_out.next().?.to);
    try testing.expect(a_out.next() == null);

    // Port-level analysis over declared ports: comp_b's grade_in is unwired.
    var unconnected: std.ArrayList([]const u8) = .empty;
    defer unconnected.deinit(testing.allocator);
    try collectUnconnectedInputs(&g, "comp_b", &unconnected);
    try testing.expectEqual(@as(usize, 1), unconnected.items.len);
    try testing.expectEqualStrings("grade_in", unconnected.items[0]);

    // a_ctrl's only input is fed by a_filter, so it has none unconnected.
    var ctrl_unconnected: std.ArrayList([]const u8) = .empty;
    defer ctrl_unconnected.deinit(testing.allocator);
    try collectUnconnectedInputs(&g, "a_ctrl", &ctrl_unconnected);
    try testing.expectEqual(@as(usize, 0), ctrl_unconnected.items.len);
}

test "integer ids" {
    var g = PortGraph(u32, void, void, void).init(testing.allocator);
    defer g.deinit();
    try g.addNode(1, {}, null);
    try g.addNode(2, {}, 1);
    try g.addPort(1, "out", .out, {});
    try g.addPort(2, "in", .in, {});
    try g.addEdge(1, "out", 2, "in", {});
    try testing.expectEqual(@as(u32, 1), g.parent(2).?);
    var ch = g.children(1);
    try testing.expectEqual(@as(u32, 2), ch.next().?);
}
