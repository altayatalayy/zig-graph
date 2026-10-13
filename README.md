# zig-graph

Small Zig 0.17 graph library with three focused types:

- **`Dag`** — a directed dependency DAG: cycle-safe edge insertion,
  topological sort, stable topological sort, and topological generations.
- **`MultiDiGraph`** — a directed multigraph with node and edge payloads:
  adjacency queries and induced subgraphs.
- **`PortGraph`** — a hierarchical directed multigraph whose nodes declare
  first-class ports and may contain child nodes: a component built from
  subcomponents that are wired to each other through ports.

## Dag

`addEdge(from, to)` means **`from` must come before `to`** (`from` is a
dependency of `to`). Edges that would create a cycle, self edges, and
duplicate edges are rejected with distinct errors.

### Node requirements

- `Node` is a user-supplied struct, stored by shallow copy.
- `Node` must have an unsigned integer `id` field; `NodeId` is inferred from it.
- Node ids must be unique; `addNode` fails on duplicates.

### Stable ordering

`stableTopologicalSort` and `stableTopologicalGenerations` only compile when a
stable order is available:

- `dag.Dag(Node, orderFn)` with
  `?*const fn (*const Node, *const Node) dag.Ordering` (`.lt` / `.gt`).
  When non-null, the function must be a deterministic, total order; any
  `key` field is ignored.
- `dag.Dag(Node, null)` where `Node` has a `key: []const u8` (or `[]u8`)
  field: ordered by `key`, ties broken by `id`.

### Usage

```zig
const graph = @import("graph");

const Task = struct { id: u32, key: []const u8 };

var d = graph.Dag(Task, null).init(alloc);
defer d.deinit();

try d.addNode(.{ .id = 1, .key = "build" });
try d.addNode(.{ .id = 2, .key = "test" });
try d.addEdge(1, 2); // 1 must come before 2

const order = try d.topologicalSort(); // []u32, caller frees
defer alloc.free(order);

const stable = try d.stableTopologicalSort();
defer alloc.free(stable);
```

## MultiDiGraph

`MultiDiGraph(Id, NodePayload, EdgePayload)`: nodes keyed by `Id`
(`[]const u8`, or an integer/enum) carry a `NodePayload`; edges are directed
`from -> to`, carry an `EdgePayload`, and may be parallel (it is a multigraph).
Node and edge insertion order is preserved. Ids and payloads are borrowed
(shallow copy); the caller keeps the backing memory alive.

```zig
const graph = @import("graph");

const Node = struct { kind: enum { gateway, activity } };
const Edge = struct { src_port: []const u8, dst_port: []const u8 };

var g = graph.MultiDiGraph([]const u8, Node, Edge).init(alloc);
defer g.deinit();

try g.addNode("gw", .{ .kind = .gateway });
try g.addNode("act", .{ .kind = .activity });
try g.addEdge("gw", "act", .{ .src_port = "speed", .dst_port = "speed_in" });

var it = g.outEdges("gw"); // also inEdges; empty iterator if the node is absent
while (it.next()) |e| {
    _ = e.to;
    _ = e.payload.src_port;
}

var sub = try g.inducedSubgraph(&.{ "gw", "act" }); // caller owns the result
defer sub.deinit();
```

## PortGraph

`PortGraph(Id, NodePayload, PortPayload, EdgePayload)`: nodes keyed by `Id`
(`[]const u8`, or an integer/enum) carry a `NodePayload` and declare named,
directed **ports** (`PortPayload`). Edges connect one node's port to another's
and carry an `EdgePayload`; parallel edges are allowed.

Hierarchy is a containment overlay: a node may name a `parent`, and a node's
`children` are the nodes that name it. The children of a node are its internal
subgraph. Edges may connect siblings or cross one level (port delegation).
`Direction` records a port's role for consumers like code generation; it is not
enforced on edges, so a component's external input can drive its children. Ids,
port names, and payloads are borrowed (shallow copy). It is a plain container —
for acyclicity or ordering over a level, feed that level's edges to `Dag`.

```zig
const graph = @import("graph");

const Node = struct { kind: enum { component, subcomponent } };
const Type = struct { data_type: []const u8 };

var g = graph.PortGraph([]const u8, Node, Type, void).init(alloc);
defer g.deinit();

try g.addNode("comp", .{ .kind = .component }, null);
try g.addNode("ctrl", .{ .kind = .subcomponent }, "comp"); // child of comp
try g.addPort("comp", "speed_in", .in, .{ .data_type = "Speed" });
try g.addPort("ctrl", "speed_in", .in, .{ .data_type = "Speed" });
try g.addEdge("comp", "speed_in", "ctrl", "speed_in", {}); // boundary delegation

var kids = g.children("comp"); // also parent, ports, outEdges, inEdges
while (kids.next()) |id| _ = id;
```

Run tests with `zig build test`.
