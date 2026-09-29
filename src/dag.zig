//! Dag: a small directed dependency DAG.
//!
//! Edge direction is hardcoded: an edge `from -> to` means `from` must come
//! before `to` in every topological ordering (`from` is a dependency of `to`).
//!
//! Cycles are rejected when the edge is added; the sort functions still
//! defensively return `error.CycleDetected` if they ever encounter one.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Result of comparing two distinct nodes for stable ordering. There is
/// deliberately no equality variant: a stable order must be total, so every
/// comparison of two distinct nodes must decide which comes first.
pub const Ordering = enum { lt, gt };

/// A DAG over `Node`, which must be a struct with an unsigned integer `id`
/// field. `NodeId` is inferred from that field. Nodes are stored as shallow
/// copies.
///
/// `order_fn` selects the stable order used by the stable sorting methods:
///
/// - `null`: the stable methods exist only when `Node` has a `key` field of
///   type `[]const u8` or `[]u8`; they order by `key`, breaking ties by `id`.
/// - `?*const fn (*const Node, *const Node) Ordering`: stable sorting uses
///   this function when non-null; any `key` field is neither required nor
///   inspected. The function is the caller's contract: it must define a
///   deterministic, total order over the nodes (never compare two distinct
///   nodes as equal).
pub fn Dag(comptime Node: type, comptime order_fn: ?*const fn (*const Node, *const Node) Ordering) type {
    if (@typeInfo(Node) != .@"struct") {
        @compileError("Dag node type must be a struct, got '" ++ @typeName(Node) ++ "'");
    }
    if (!@hasField(Node, "id")) {
        @compileError("Dag node type '" ++ @typeName(Node) ++ "' must have an 'id' field");
    }
    const Id = @FieldType(Node, "id");
    if (@typeInfo(Id) != .int or @typeInfo(Id).int.signedness != .unsigned) {
        @compileError("'" ++ @typeName(Node) ++ ".id' must be an unsigned integer, got '" ++
            @typeName(Id) ++ "'");
    }

    return struct {
        const Self = @This();

        pub const NodeId = Id;

        pub const AddNodeError = Allocator.Error || error{DuplicateNodeId};
        pub const AddEdgeError = Allocator.Error || error{
            MissingNode,
            SelfEdge,
            DuplicateEdge,
            CycleDetected,
        };
        pub const SortError = Allocator.Error || error{CycleDetected};

        /// The stable order in effect: a custom order function wins; otherwise
        /// a `key` field enables the default key-then-id order; otherwise the
        /// stable methods are unavailable. The `key` field is only inspected
        /// when no custom order function was supplied.
        const stable_order: ?*const fn (*const Node, *const Node) Ordering = order_fn orelse blk: {
            if (!@hasField(Node, "key")) break :blk null;
            const Key = @FieldType(Node, "key");
            if (Key != []const u8 and Key != []u8) {
                @compileError("'" ++ @typeName(Node) ++
                    ".key' must be []const u8 or []u8 for stable ordering, got '" ++
                    @typeName(Key) ++ "'");
            }
            break :blk keyThenIdOrder;
        };

        const Entry = struct {
            node: Node,
            successors: std.ArrayList(NodeId),
        };

        allocator: Allocator,
        /// Insertion-ordered map; regular topological sorting breaks ties in
        /// node insertion order.
        entries: std.AutoArrayHashMapUnmanaged(NodeId, Entry),

        pub fn init(allocator: Allocator) Self {
            return .{ .allocator = allocator, .entries = .empty };
        }

        pub fn deinit(self: *Self) void {
            for (self.entries.values()) |*entry| {
                entry.successors.deinit(self.allocator);
            }
            self.entries.deinit(self.allocator);
            self.* = undefined;
        }

        /// Stores a shallow copy of `n`. Fails with `error.DuplicateNodeId`
        /// if a node with the same id already exists.
        pub fn addNode(self: *Self, n: Node) AddNodeError!void {
            const gop = try self.entries.getOrPut(self.allocator, n.id);
            if (gop.found_existing) return error.DuplicateNodeId;
            gop.value_ptr.* = .{ .node = n, .successors = .empty };
        }

        /// Adds the edge `from -> to`: `from` must come before `to`.
        /// Fails with `error.MissingNode` if either endpoint was not added,
        /// `error.SelfEdge` if `from == to`, `error.DuplicateEdge` if the
        /// edge already exists, and `error.CycleDetected` if the edge would
        /// create a cycle.
        pub fn addEdge(self: *Self, from: NodeId, to: NodeId) AddEdgeError!void {
            if (from == to) return error.SelfEdge;
            const from_entry = self.entries.getPtr(from) orelse return error.MissingNode;
            if (!self.entries.contains(to)) return error.MissingNode;
            for (from_entry.successors.items) |succ| {
                if (succ == to) return error.DuplicateEdge;
            }
            if (try self.pathExists(to, from)) return error.CycleDetected;
            try from_entry.successors.append(self.allocator, to);
        }

        /// Returns a shallow copy of the node with `id`, or null if absent.
        pub fn node(self: *const Self, id: NodeId) ?Node {
            const entry = self.entries.getPtr(id) orelse return null;
            return entry.node;
        }

        /// Returns the node ids in a valid topological order, breaking ties
        /// in node insertion order. The caller owns the returned slice and
        /// must free it with this dag's allocator.
        pub fn topologicalSort(self: *const Self) SortError![]NodeId {
            const n = self.entries.count();
            const in_degree = try self.inDegrees();
            defer self.allocator.free(in_degree);

            const queue = try self.allocator.alloc(usize, n);
            defer self.allocator.free(queue);
            var tail: usize = 0;
            for (in_degree, 0..) |degree, idx| {
                if (degree == 0) {
                    queue[tail] = idx;
                    tail += 1;
                }
            }

            const result = try self.allocator.alloc(NodeId, n);
            errdefer self.allocator.free(result);
            const ids = self.entries.keys();
            var head: usize = 0;
            while (head < tail) {
                const idx = queue[head];
                result[head] = ids[idx];
                head += 1;
                for (self.entries.values()[idx].successors.items) |succ| {
                    const succ_idx = self.entries.getIndex(succ).?;
                    in_degree[succ_idx] -= 1;
                    if (in_degree[succ_idx] == 0) {
                        queue[tail] = succ_idx;
                        tail += 1;
                    }
                }
            }
            if (head != n) return error.CycleDetected;
            return result;
        }

        /// Returns the node ids grouped into generations: generation 0 has no
        /// dependencies, and every node in generation k only depends on nodes
        /// in earlier generations. Within a generation, ids follow node
        /// insertion order. The caller owns the outer slice and every inner
        /// slice and must free them all with this dag's allocator.
        pub fn topologicalGenerations(self: *const Self) SortError![][]NodeId {
            return self.generations(false);
        }

        /// Like `topologicalSort`, but breaks ties using the stable order
        /// (custom order function, or `key` then `id`), so the result is
        /// independent of insertion order. Only available when a stable order
        /// exists; see `Dag`.
        pub fn stableTopologicalSort(self: *const Self) SortError![]NodeId {
            comptime requireStableOrder("stableTopologicalSort");
            const n = self.entries.count();
            const in_degree = try self.inDegrees();
            defer self.allocator.free(in_degree);

            var ready: std.ArrayList(usize) = .empty;
            defer ready.deinit(self.allocator);
            try ready.ensureTotalCapacity(self.allocator, n);
            for (in_degree, 0..) |degree, idx| {
                if (degree == 0) ready.appendAssumeCapacity(idx);
            }

            const result = try self.allocator.alloc(NodeId, n);
            errdefer self.allocator.free(result);
            const ids = self.entries.keys();
            const entries = self.entries.values();
            var count: usize = 0;
            while (ready.items.len > 0) {
                var min_pos: usize = 0;
                for (ready.items[1..], 1..) |idx, pos| {
                    const min_idx = ready.items[min_pos];
                    if ((stable_order.?)(&entries[idx].node, &entries[min_idx].node) == .lt) {
                        min_pos = pos;
                    }
                }
                const idx = ready.swapRemove(min_pos);
                result[count] = ids[idx];
                count += 1;
                for (entries[idx].successors.items) |succ| {
                    const succ_idx = self.entries.getIndex(succ).?;
                    in_degree[succ_idx] -= 1;
                    if (in_degree[succ_idx] == 0) ready.appendAssumeCapacity(succ_idx);
                }
            }
            if (count != n) return error.CycleDetected;
            return result;
        }

        /// Like `topologicalGenerations`, but each generation is sorted by the
        /// stable order (custom order function, or `key` then `id`). Only
        /// available when a stable order exists; see `Dag`.
        pub fn stableTopologicalGenerations(self: *const Self) SortError![][]NodeId {
            comptime requireStableOrder("stableTopologicalGenerations");
            return self.generations(true);
        }

        fn requireStableOrder(comptime fn_name: []const u8) void {
            if (stable_order == null) {
                @compileError(fn_name ++ " is unavailable: '" ++ @typeName(Node) ++
                    "' has no 'key: []const u8' field and no order function was " ++
                    "supplied; add a 'key' field or pass an order function to Dag");
            }
        }

        fn keyThenIdOrder(a: *const Node, b: *const Node) Ordering {
            return switch (std.mem.order(u8, a.key, b.key)) {
                .lt => .lt,
                .gt => .gt,
                .eq => if (a.id < b.id) Ordering.lt else .gt,
            };
        }

        /// In-degree of every node, indexed by entry index. Caller frees.
        fn inDegrees(self: *const Self) Allocator.Error![]usize {
            const degrees = try self.allocator.alloc(usize, self.entries.count());
            @memset(degrees, 0);
            for (self.entries.values()) |entry| {
                for (entry.successors.items) |succ| {
                    degrees[self.entries.getIndex(succ).?] += 1;
                }
            }
            return degrees;
        }

        /// Depth-first reachability from `start` to `target` along edges.
        fn pathExists(self: *const Self, start: NodeId, target: NodeId) Allocator.Error!bool {
            var visited = try std.DynamicBitSetUnmanaged.initEmpty(
                self.allocator,
                self.entries.count(),
            );
            defer visited.deinit(self.allocator);
            var stack: std.ArrayList(NodeId) = .empty;
            defer stack.deinit(self.allocator);

            try stack.append(self.allocator, start);
            while (stack.pop()) |id| {
                if (id == target) return true;
                const idx = self.entries.getIndex(id).?;
                if (visited.isSet(idx)) continue;
                visited.set(idx);
                for (self.entries.values()[idx].successors.items) |succ| {
                    try stack.append(self.allocator, succ);
                }
            }
            return false;
        }

        fn generations(self: *const Self, comptime stable: bool) SortError![][]NodeId {
            const n = self.entries.count();
            const in_degree = try self.inDegrees();
            defer self.allocator.free(in_degree);

            var current: std.ArrayList(usize) = .empty;
            defer current.deinit(self.allocator);
            var next: std.ArrayList(usize) = .empty;
            defer next.deinit(self.allocator);

            for (in_degree, 0..) |degree, idx| {
                if (degree == 0) try current.append(self.allocator, idx);
            }

            var gens: std.ArrayList([]NodeId) = .empty;
            errdefer {
                for (gens.items) |gen| self.allocator.free(gen);
                gens.deinit(self.allocator);
            }

            const ids = self.entries.keys();
            var processed: usize = 0;
            while (current.items.len > 0) {
                if (stable) self.sortByStableOrder(current.items);

                const gen = try self.allocator.alloc(NodeId, current.items.len);
                errdefer self.allocator.free(gen);
                for (current.items, gen) |idx, *out| out.* = ids[idx];
                try gens.append(self.allocator, gen);
                processed += current.items.len;

                next.clearRetainingCapacity();
                for (current.items) |idx| {
                    for (self.entries.values()[idx].successors.items) |succ| {
                        const succ_idx = self.entries.getIndex(succ).?;
                        in_degree[succ_idx] -= 1;
                        if (in_degree[succ_idx] == 0) try next.append(self.allocator, succ_idx);
                    }
                }
                std.mem.swap(std.ArrayList(usize), &current, &next);
            }
            if (processed != n) return error.CycleDetected;
            return gens.toOwnedSlice(self.allocator);
        }

        fn sortByStableOrder(self: *const Self, indices: []usize) void {
            const entries = self.entries.values();
            std.mem.sort(usize, indices, entries, struct {
                fn lessThan(ctx: []const Entry, a: usize, b: usize) bool {
                    return (stable_order.?)(&ctx[a].node, &ctx[b].node) == .lt;
                }
            }.lessThan);
        }
    };
}

const testing = std.testing;

const PlainNode = struct { id: u32 };
const KeyedNode = struct { id: u32, key: []const u8 };

fn descendingById(a: *const PlainNode, b: *const PlainNode) Ordering {
    return if (a.id > b.id) .lt else .gt;
}

test "addNode rejects duplicate node ids" {
    var d = Dag(PlainNode, null).init(testing.allocator);
    defer d.deinit();
    try d.addNode(.{ .id = 1 });
    try testing.expectError(error.DuplicateNodeId, d.addNode(.{ .id = 1 }));
}

test "addEdge rejects missing endpoints" {
    var d = Dag(PlainNode, null).init(testing.allocator);
    defer d.deinit();
    try d.addNode(.{ .id = 1 });
    try testing.expectError(error.MissingNode, d.addEdge(1, 2));
    try testing.expectError(error.MissingNode, d.addEdge(2, 1));
}

test "addEdge rejects self edges" {
    var d = Dag(PlainNode, null).init(testing.allocator);
    defer d.deinit();
    try d.addNode(.{ .id = 1 });
    try testing.expectError(error.SelfEdge, d.addEdge(1, 1));
}

test "addEdge rejects duplicate edges" {
    var d = Dag(PlainNode, null).init(testing.allocator);
    defer d.deinit();
    try d.addNode(.{ .id = 1 });
    try d.addNode(.{ .id = 2 });
    try d.addEdge(1, 2);
    try testing.expectError(error.DuplicateEdge, d.addEdge(1, 2));
}

test "addEdge rejects edges that would create a cycle" {
    var d = Dag(PlainNode, null).init(testing.allocator);
    defer d.deinit();
    try d.addNode(.{ .id = 1 });
    try d.addNode(.{ .id = 2 });
    try d.addNode(.{ .id = 3 });
    try d.addEdge(1, 2);
    try d.addEdge(2, 3);
    try testing.expectError(error.CycleDetected, d.addEdge(2, 1));
    try testing.expectError(error.CycleDetected, d.addEdge(3, 1));
}

test "node returns a shallow copy or null" {
    var d = Dag(PlainNode, null).init(testing.allocator);
    defer d.deinit();
    try d.addNode(.{ .id = 7 });
    try testing.expectEqual(PlainNode{ .id = 7 }, d.node(7).?);
    try testing.expectEqual(@as(?PlainNode, null), d.node(8));
}

test "topologicalSort orders dependencies first, ties by insertion order" {
    var d = Dag(PlainNode, null).init(testing.allocator);
    defer d.deinit();
    try d.addNode(.{ .id = 4 });
    try d.addNode(.{ .id = 1 });
    try d.addNode(.{ .id = 2 });
    try d.addNode(.{ .id = 3 });
    try d.addEdge(1, 2); // diamond: 1 -> {2, 3} -> 4
    try d.addEdge(1, 3);
    try d.addEdge(2, 4);
    try d.addEdge(3, 4);

    const order = try d.topologicalSort();
    defer testing.allocator.free(order);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, order);
}

test "topologicalGenerations groups nodes by dependency depth" {
    var d = Dag(PlainNode, null).init(testing.allocator);
    defer d.deinit();
    try d.addNode(.{ .id = 1 });
    try d.addNode(.{ .id = 2 });
    try d.addNode(.{ .id = 3 });
    try d.addNode(.{ .id = 4 });
    try d.addEdge(1, 2);
    try d.addEdge(1, 3);
    try d.addEdge(2, 4);
    try d.addEdge(3, 4);

    const gens = try d.topologicalGenerations();
    defer {
        for (gens) |gen| testing.allocator.free(gen);
        testing.allocator.free(gens);
    }
    try testing.expectEqual(@as(usize, 3), gens.len);
    try testing.expectEqualSlices(u32, &.{1}, gens[0]);
    try testing.expectEqualSlices(u32, &.{ 2, 3 }, gens[1]);
    try testing.expectEqualSlices(u32, &.{4}, gens[2]);
}

test "stableTopologicalSort orders by key, then id" {
    var d = Dag(KeyedNode, null).init(testing.allocator);
    defer d.deinit();
    try d.addNode(.{ .id = 1, .key = "c" });
    try d.addNode(.{ .id = 4, .key = "a" });
    try d.addNode(.{ .id = 2, .key = "a" });
    try d.addNode(.{ .id = 3, .key = "b" });
    try d.addNode(.{ .id = 5, .key = "d" });
    try d.addEdge(1, 5); // 5 ("d") must still come after 1 ("c")

    const order = try d.stableTopologicalSort();
    defer testing.allocator.free(order);
    // "a" tie between ids 2 and 4 is broken by id.
    try testing.expectEqualSlices(u32, &.{ 2, 4, 3, 1, 5 }, order);
}

test "stableTopologicalGenerations sorts each generation by key" {
    var d = Dag(KeyedNode, null).init(testing.allocator);
    defer d.deinit();
    try d.addNode(.{ .id = 1, .key = "z" });
    try d.addNode(.{ .id = 2, .key = "b" });
    try d.addNode(.{ .id = 3, .key = "a" });
    try d.addEdge(1, 2);
    try d.addEdge(1, 3);

    const gens = try d.stableTopologicalGenerations();
    defer {
        for (gens) |gen| testing.allocator.free(gen);
        testing.allocator.free(gens);
    }
    try testing.expectEqual(@as(usize, 2), gens.len);
    try testing.expectEqualSlices(u32, &.{1}, gens[0]);
    try testing.expectEqualSlices(u32, &.{ 3, 2 }, gens[1]);
}

test "stableTopologicalSort with a custom order function" {
    var d = Dag(PlainNode, descendingById).init(testing.allocator);
    defer d.deinit();
    try d.addNode(.{ .id = 1 });
    try d.addNode(.{ .id = 2 });
    try d.addNode(.{ .id = 3 });
    try d.addEdge(1, 3); // keeps 1 before 3 despite descending order

    const order = try d.stableTopologicalSort();
    defer testing.allocator.free(order);
    try testing.expectEqualSlices(u32, &.{ 2, 1, 3 }, order);
}

test "custom order function does not require a valid key field" {
    // 'key' is not []const u8 here; with a custom order it must be ignored.
    const OddNode = struct { id: u8, key: u64 };
    const oddOrder = struct {
        fn order(a: *const OddNode, b: *const OddNode) Ordering {
            return if (a.id < b.id) .lt else .gt;
        }
    }.order;

    var d = Dag(OddNode, oddOrder).init(testing.allocator);
    defer d.deinit();
    try d.addNode(.{ .id = 2, .key = 0 });
    try d.addNode(.{ .id = 1, .key = 0 });

    const order = try d.stableTopologicalSort();
    defer testing.allocator.free(order);
    try testing.expectEqualSlices(u8, &.{ 1, 2 }, order);
}
