//! zig-graph: small graph data structures.
//!
//! - `Dag`: a directed dependency DAG with cycle-safe edge insertion and
//!   topological ordering (`from -> to` means `from` must come before `to`).
//! - `MultiDiGraph`: a directed multigraph with node and edge payloads,
//!   adjacency queries, and induced subgraphs.
//! - `PortGraph`: a hierarchical directed multigraph whose nodes declare
//!   first-class ports and may contain child nodes (e.g. components built from
//!   subcomponents wired through ports).

const dag = @import("dag.zig");
const multi_di_graph = @import("multi_di_graph.zig");
const port_graph = @import("port_graph.zig");

pub const Dag = dag.Dag;
pub const Ordering = dag.Ordering;
pub const MultiDiGraph = multi_di_graph.MultiDiGraph;
pub const PortGraph = port_graph.PortGraph;
pub const Direction = port_graph.Direction;

test {
    _ = dag;
    _ = multi_di_graph;
    _ = port_graph;
}
