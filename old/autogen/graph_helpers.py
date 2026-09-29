from dataclasses import dataclass
from typing import Dict, List, Set, Tuple

from typing_extensions import Literal

NodeKind = Literal["gateway", "activity"]


@dataclass(frozen=True)
class GraphNode:
    name: str
    type: str
    kind: NodeKind


@dataclass(frozen=True)
class GraphEdge:
    src: GraphNode
    src_port: str
    dst: GraphNode
    dst_port: str
    data_type: str


@dataclass(frozen=True)
class ApplicationGraph:
    nodes_by_name: Dict[str, GraphNode]
    edges: List[GraphEdge]


def build_induced_subgraph(
    full_graph: ApplicationGraph,
    selected_activity_names: List[str],
) -> ApplicationGraph:
    assert (
        isinstance(selected_activity_names, list)
        and len(selected_activity_names) > 0
        and len(set(selected_activity_names)) == len(selected_activity_names)
    )

    selected_set: Set[str] = set()

    for name in selected_activity_names:
        assert name in full_graph.nodes_by_name, f"Unknown node: {name}"
        node = full_graph.nodes_by_name[name]

        assert node.kind == "activity", f"Node is not activity: {name}"
        selected_set.add(name)

    sub_nodes: Dict[str, GraphNode] = {
        name: full_graph.nodes_by_name[name] for name in selected_set
    }

    sub_edges: List[GraphEdge] = []

    for edge in full_graph.edges:
        if edge.src.name in selected_set and edge.dst.name in selected_set:
            sub_edges.append(edge)

    return ApplicationGraph(
        nodes_by_name=sub_nodes,
        edges=sub_edges,
    )


def validate_subgraph(
    full_graph: ApplicationGraph,
    subgraph: ApplicationGraph,
) -> None:
    for name, node in subgraph.nodes_by_name.items():
        assert (
            name in full_graph.nodes_by_name
        ), f"Subgraph node not in full graph: {name}"
        assert full_graph.nodes_by_name[name] == node, f"Node mismatch: {name}"

    full_edge_set: Set[Tuple[str, str, str, str, str]] = {
        (
            edge.src.name,
            edge.src_port,
            edge.dst.name,
            edge.dst_port,
            edge.data_type,
        )
        for edge in full_graph.edges
    }

    sub_edge_set: Set[Tuple[str, str, str, str, str]] = set()

    for edge in subgraph.edges:
        assert (
            edge.src.name in subgraph.nodes_by_name
        ), f"Subgraph edge source missing from subgraph nodes: {edge.src.name}"
        assert (
            edge.dst.name in subgraph.nodes_by_name
        ), f"Subgraph edge destination missing from subgraph nodes: {edge.dst.name}"

        edge_key = (
            edge.src.name,
            edge.src_port,
            edge.dst.name,
            edge.dst_port,
            edge.data_type,
        )

        assert edge_key in full_edge_set, f"Edge not in full graph: {edge_key}"
        sub_edge_set.add(edge_key)

    sub_node_names: Set[str] = set(subgraph.nodes_by_name.keys())

    induced_edge_set: Set[Tuple[str, str, str, str, str]] = {
        (
            edge.src.name,
            edge.src_port,
            edge.dst.name,
            edge.dst_port,
            edge.data_type,
        )
        for edge in full_graph.edges
        if edge.src.name in sub_node_names and edge.dst.name in sub_node_names
    }

    assert sub_edge_set == induced_edge_set, (
        f"Subgraph is not induced. "
        f"Expected edges: {sorted(induced_edge_set)}, "
        f"actual edges: {sorted(sub_edge_set)}"
    )


def get_all_output_ports_by_activity(
    full_graph: ApplicationGraph,
    subgraph: ApplicationGraph,
) -> Dict[str, List[Tuple[str, str]]]:
    result: Dict[str, List[Tuple[str, str]]] = {}

    for instance_name, node in subgraph.nodes_by_name.items():
        if node.kind != "activity":
            continue

        seen: Set[Tuple[str, str]] = set()
        outputs: List[Tuple[str, str]] = []

        for edge in full_graph.edges:
            if edge.src.name != instance_name:
                continue

            port_info = (edge.data_type, edge.src_port)
            if port_info in seen:
                continue

            seen.add(port_info)
            outputs.append(port_info)

        result[instance_name] = outputs

    return result


def get_unconnected_input_ports_by_activity(
    full_graph: ApplicationGraph,
    subgraph: ApplicationGraph,
) -> Dict[str, List[Tuple[str, str]]]:
    result: Dict[str, List[Tuple[str, str]]] = {}

    subgraph_connected_inputs: Dict[str, Set[str]] = {}

    for edge in subgraph.edges:
        if edge.dst.kind != "activity":
            continue

        if edge.dst.name not in subgraph_connected_inputs:
            subgraph_connected_inputs[edge.dst.name] = set()

        subgraph_connected_inputs[edge.dst.name].add(edge.dst_port)

    for instance_name, node in subgraph.nodes_by_name.items():
        if node.kind != "activity":
            continue

        all_inputs_seen: Set[Tuple[str, str]] = set()
        all_inputs_in_full_graph: List[Tuple[str, str]] = []

        for edge in full_graph.edges:
            if edge.dst.name != instance_name:
                continue

            port_info = (edge.data_type, edge.dst_port)
            if port_info in all_inputs_seen:
                continue

            all_inputs_seen.add(port_info)
            all_inputs_in_full_graph.append(port_info)

        connected_input_names = subgraph_connected_inputs.get(instance_name, set())

        unconnected_inputs: List[Tuple[str, str]] = []
        for port_type, port_name in all_inputs_in_full_graph:
            if port_name not in connected_input_names:
                unconnected_inputs.append((port_type, port_name))

        result[instance_name] = unconnected_inputs

    return result
