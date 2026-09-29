import os
import re
from typing import Any, Dict, List, Optional, Set, Tuple

import yaml
from jinja2 import Environment, FileSystemLoader, StrictUndefined

from graph_helpers import (
    ApplicationGraph,
    GraphEdge,
    GraphNode,
    build_induced_subgraph,
    get_all_output_ports_by_activity,
    get_unconnected_input_ports_by_activity,
    validate_subgraph,
)

from gen_reader import build_input_gateway_reader_context, print_csv_header_schema


def assert_file_readable(path: str) -> None:
    assert isinstance(path, str)
    assert path.strip() != ""
    assert os.path.exists(path), f"File does not exist: {path}"
    assert os.path.isfile(path), f"Path is not a file: {path}"
    assert os.access(path, os.R_OK), f"File is not readable: {path}"


def assert_directory_exists(path: str) -> None:
    assert isinstance(path, str)
    assert path.strip() != ""
    assert os.path.exists(path), f"Directory does not exist: {path}"
    assert os.path.isdir(path), f"Path is not a directory: {path}"


def load_yaml_file(path: str) -> Dict[str, Any]:
    assert_file_readable(path)
    with open(path, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f)
    assert data is not None, f"YAML file is empty: {path}"
    assert isinstance(data, dict), f"YAML root must be a mapping: {path}"
    return data


def to_pascal_case(value: str) -> str:
    parts = re.split(r"[_\-\s]+", value.strip())
    return "".join(part[:1].upper() + part[1:] for part in parts if part)


def normalize_gateway_port_name(port_name: str) -> str:
    assert isinstance(port_name, str)
    assert port_name.strip() != ""
    value = port_name.strip().lower()
    value = re.sub(r"_(input|output)$", "", value)
    value = value.replace("_", "")
    return value


def infer_instance_name(component_name: str) -> str:
    return f"{component_name}_activity_instance"


def infer_component_name_from_instance_name(instance_name: str) -> str:
    suffix = "_activity_instance"
    assert instance_name.endswith(
        suffix
    ), f"Activity instance name does not end with '{suffix}': {instance_name}"
    return instance_name[: -len(suffix)]


def parse_endpoint(
    value: str, current_instance_name: Optional[str]
) -> Tuple[Optional[str], str]:
    assert isinstance(value, str)
    assert value.strip() != ""
    if "." in value:
        instance_name, port_name = value.split(".", 1)
        assert instance_name.strip() != ""
        assert port_name.strip() != ""
        return instance_name, port_name
    assert (
        current_instance_name is not None
    ), f"Endpoint without instance is invalid here: {value}"
    return current_instance_name, value


def build_component_port_type_maps(
    repo_root: str,
    activity_instance_names: List[str],
) -> Tuple[Dict[str, Dict[str, str]], Dict[str, Dict[str, str]]]:
    input_type_map_by_instance: Dict[str, Dict[str, str]] = {}
    output_type_map_by_instance: Dict[str, Dict[str, str]] = {}

    for instance_name in activity_instance_names:
        component_name = infer_component_name_from_instance_name(instance_name)
        component_activity_path = os.path.join(
            repo_root,
            component_name,
            "generated",
            "edms",
            "activities",
            f"{to_pascal_case(component_name)}.activity.yaml",
        )

        data = load_yaml_file(component_activity_path)

        raw_input_ports = data.get("input_ports", [])
        raw_output_ports = data.get("output_ports", [])

        assert isinstance(
            raw_input_ports, list
        ), f"input_ports must be a list: {component_activity_path}"
        assert isinstance(
            raw_output_ports, list
        ), f"output_ports must be a list: {component_activity_path}"

        input_type_map: Dict[str, str] = {}
        output_type_map: Dict[str, str] = {}

        for item in raw_input_ports:
            assert isinstance(
                item, dict
            ), f"Invalid input port entry: {component_activity_path}"
            port_name = item.get("name")
            port_type = item.get("type")
            assert isinstance(
                port_name, str
            ), f"Invalid input port name: {component_activity_path}"
            assert isinstance(
                port_type, str
            ), f"Invalid input port type for {port_name}: {component_activity_path}"
            assert (
                port_name not in input_type_map
            ), f"Duplicate input port '{port_name}' in {component_activity_path}"
            input_type_map[port_name] = port_type

        for item in raw_output_ports:
            assert isinstance(
                item, dict
            ), f"Invalid output port entry: {component_activity_path}"
            port_name = item.get("name")
            port_type = item.get("type")
            assert isinstance(
                port_name, str
            ), f"Invalid output port name: {component_activity_path}"
            assert isinstance(
                port_type, str
            ), f"Invalid output port type for {port_name}: {component_activity_path}"
            assert (
                port_name not in output_type_map
            ), f"Duplicate output port '{port_name}' in {component_activity_path}"
            output_type_map[port_name] = port_type

        input_type_map_by_instance[instance_name] = input_type_map
        output_type_map_by_instance[instance_name] = output_type_map

    return input_type_map_by_instance, output_type_map_by_instance


def build_full_graph(
    repo_root: str,
    application_activity_path: str,
) -> ApplicationGraph:
    assert_directory_exists(repo_root)
    assert_file_readable(application_activity_path)

    data = load_yaml_file(application_activity_path)

    raw_activity_instances = data["activity_instances"]
    raw_gateway_instances = data["gateway_instances"]

    assert isinstance(
        raw_activity_instances, list
    ), f"'activity_instances' must be a list: {application_activity_path}"
    assert isinstance(
        raw_gateway_instances, list
    ), f"'gateway_instances' must be a list: {application_activity_path}"

    nodes_by_name: Dict[str, GraphNode] = {}
    activity_instance_names: List[str] = []

    for raw_instance in raw_activity_instances:
        assert isinstance(
            raw_instance, dict
        ), f"Invalid activity instance entry: {application_activity_path}"
        instance_name = raw_instance["name"]
        instance_type = raw_instance["type"]
        assert isinstance(
            instance_name, str
        ), f"Invalid activity instance name: {application_activity_path}"
        assert isinstance(
            instance_type, str
        ), f"Invalid activity instance type for {instance_name}: {application_activity_path}"
        assert (
            instance_name not in nodes_by_name
        ), f"Duplicate node name in activity graph: {instance_name}"

        nodes_by_name[instance_name] = GraphNode(
            name=instance_name,
            type=instance_type,
            kind="activity",
        )
        activity_instance_names.append(instance_name)

    for raw_instance in raw_gateway_instances:
        assert isinstance(
            raw_instance, dict
        ), f"Invalid gateway instance entry: {application_activity_path}"
        instance_name = raw_instance["name"]
        instance_type = raw_instance["type"]
        assert isinstance(
            instance_name, str
        ), f"Invalid gateway instance name: {application_activity_path}"
        assert isinstance(
            instance_type, str
        ), f"Invalid gateway instance type for {instance_name}: {application_activity_path}"
        assert (
            instance_name not in nodes_by_name
        ), f"Duplicate node name in activity graph: {instance_name}"

        nodes_by_name[instance_name] = GraphNode(
            name=instance_name,
            type=instance_type,
            kind="gateway",
        )

    input_type_map_by_instance, output_type_map_by_instance = (
        build_component_port_type_maps(
            repo_root=repo_root,
            activity_instance_names=activity_instance_names,
        )
    )

    edges: List[GraphEdge] = []

    all_instance_blocks: List[Dict[str, Any]] = []
    all_instance_blocks.extend(raw_gateway_instances)
    all_instance_blocks.extend(raw_activity_instances)

    for raw_instance in all_instance_blocks:
        instance_name = raw_instance["name"]
        raw_connections = raw_instance.get("connections", [])
        assert isinstance(
            raw_connections, list
        ), f"Invalid connections list for {instance_name}"

        for raw_connection in raw_connections:
            assert isinstance(
                raw_connection, dict
            ), f"Invalid connection entry for {instance_name}"
            raw_from = raw_connection.get("from")
            raw_to = raw_connection.get("to")
            assert isinstance(
                raw_from, str
            ), f"Invalid 'from' in connection for {instance_name}"
            assert isinstance(
                raw_to, str
            ), f"Invalid 'to' in connection for {instance_name}"

            src_instance_name, src_port_name = parse_endpoint(raw_from, None)
            dst_instance_name, dst_port_name = parse_endpoint(raw_to, instance_name)

            assert src_instance_name is not None
            assert dst_instance_name is not None
            assert (
                src_instance_name in nodes_by_name
            ), f"Unknown source instance '{src_instance_name}' in connection for {instance_name}"
            assert (
                dst_instance_name in nodes_by_name
            ), f"Unknown destination instance '{dst_instance_name}' in connection for {instance_name}"

            src_node = nodes_by_name[src_instance_name]
            dst_node = nodes_by_name[dst_instance_name]

            src_type: Optional[str] = None
            dst_type: Optional[str] = None

            if src_node.kind == "activity":
                assert (
                    src_instance_name in output_type_map_by_instance
                ), f"Missing output type map for activity {src_instance_name}"
                assert (
                    src_port_name in output_type_map_by_instance[src_instance_name]
                ), f"Unknown output port '{src_port_name}' for activity {src_instance_name}"
                src_type = output_type_map_by_instance[src_instance_name][src_port_name]

            if dst_node.kind == "activity":
                assert (
                    dst_instance_name in input_type_map_by_instance
                ), f"Missing input type map for activity {dst_instance_name}"
                assert (
                    dst_port_name in input_type_map_by_instance[dst_instance_name]
                ), f"Unknown input port '{dst_port_name}' for activity {dst_instance_name}"
                dst_type = input_type_map_by_instance[dst_instance_name][dst_port_name]

            assert src_type is not None or dst_type is not None, (
                f"Could not infer edge type for connection "
                f"{src_instance_name}.{src_port_name} -> {dst_instance_name}.{dst_port_name}"
            )

            if src_type is not None and dst_type is not None:
                assert src_type == dst_type, (
                    f"Type mismatch for connection "
                    f"{src_instance_name}.{src_port_name} -> {dst_instance_name}.{dst_port_name}: "
                    f"{src_type} != {dst_type}"
                )
                data_type = src_type
            elif src_type is not None:
                data_type = src_type
            else:
                assert dst_type is not None
                data_type = dst_type

            edges.append(
                GraphEdge(
                    src=src_node,
                    src_port=src_port_name,
                    dst=dst_node,
                    dst_port=dst_port_name,
                    data_type=data_type,
                )
            )

    return ApplicationGraph(
        nodes_by_name=nodes_by_name,
        edges=edges,
    )


def print_application_graph(
    graph: ApplicationGraph, title: str = "ApplicationGraph"
) -> None:

    print(title)
    print("Nodes:")
    for node_name in sorted(graph.nodes_by_name.keys()):
        node = graph.nodes_by_name[node_name]
        print(f"  - {node.name} [{node.kind}] type={node.type}")

    print("Edges:")
    for edge in graph.edges:
        print(
            f"  - {edge.src.name}.{edge.src_port} -> "
            f"{edge.dst.name}.{edge.dst_port} "
            f"type={edge.data_type}"
        )


def build_augmented_application_graph(
    subgraph: ApplicationGraph,
    unconnected_inputs_by_activity: Dict[str, List[Tuple[str, str]]],
    all_outputs_by_activity: Dict[str, List[Tuple[str, str]]],
    input_gateway_instance_name: str,
    input_gateway_type: str,
    output_gateway_instance_name: str,
    output_gateway_type: str,
) -> ApplicationGraph:
    augmented_nodes_by_name: Dict[str, GraphNode] = dict(subgraph.nodes_by_name)

    input_gateway_node = GraphNode(
        name=input_gateway_instance_name,
        type=input_gateway_type,
        kind="gateway",
    )
    output_gateway_node = GraphNode(
        name=output_gateway_instance_name,
        type=output_gateway_type,
        kind="gateway",
    )

    assert (
        input_gateway_node.name not in augmented_nodes_by_name
    ), f"Node name already exists: {input_gateway_node.name}"
    assert (
        output_gateway_node.name not in augmented_nodes_by_name
    ), f"Node name already exists: {output_gateway_node.name}"

    augmented_nodes_by_name[input_gateway_node.name] = input_gateway_node
    augmented_nodes_by_name[output_gateway_node.name] = output_gateway_node

    augmented_edges: List[GraphEdge] = list(subgraph.edges)

    input_gateway_port_types: Dict[str, str] = {}
    output_gateway_port_types: Dict[str, str] = {}

    for activity_name, activity_node in subgraph.nodes_by_name.items():

        for port_type, port_name in unconnected_inputs_by_activity.get(
            activity_name, []
        ):
            gateway_port_name = normalize_gateway_port_name(port_name)
            if gateway_port_name in input_gateway_port_types:
                assert input_gateway_port_types[gateway_port_name] == port_type
            else:
                input_gateway_port_types[gateway_port_name] = port_type

            augmented_edges.append(
                GraphEdge(
                    src=input_gateway_node,
                    src_port=gateway_port_name,
                    dst=activity_node,
                    dst_port=port_name,
                    data_type=port_type,
                )
            )

        for port_type, port_name in all_outputs_by_activity.get(activity_name, []):
            gateway_port_name = normalize_gateway_port_name(port_name)
            if gateway_port_name in output_gateway_port_types:
                assert output_gateway_port_types[gateway_port_name] == port_type
            else:
                output_gateway_port_types[gateway_port_name] = port_type

            augmented_edges.append(
                GraphEdge(
                    src=activity_node,
                    src_port=port_name,
                    dst=output_gateway_node,
                    dst_port=gateway_port_name,
                    data_type=port_type,
                )
            )

    return ApplicationGraph(
        nodes_by_name=augmented_nodes_by_name,
        edges=augmented_edges,
    )


def get_dependencies_per_activity(full_graph: ApplicationGraph, selected_activity_names: List[str]) -> Dict[str, List[Dict[str, str]]]:
    # return list of {"component_name": ...} per activity name
    from collections import defaultdict

    rv = defaultdict(list)

    for san in selected_activity_names:
        node = full_graph.nodes_by_name[san]
        for edge in full_graph.edges:
            # use == directly instead of using on name
            if edge.dst.name == node.name:
                rv[san].append({"component_name": edge.src.name[:-18]})

    return rv




def generate_files(
    templates_dir: str,
    repo_root: str,
    activities_root: str,
    output_dir: str,
    test_name: str,
    augmented_graph: ApplicationGraph,
    selected_activity_names: List[str],
    input_gateway_instance_name: str,
    output_gateway_instance_name: str,
    input_gateway_class_name: str,
    output_gateway_class_name: str,
    full_graph: ApplicationGraph,
) -> None:
    assert_directory_exists(templates_dir)
    assert isinstance(output_dir, str) and output_dir.strip() != ""
    assert isinstance(test_name, str) and test_name.strip() != ""
    assert input_gateway_instance_name in augmented_graph.nodes_by_name
    assert output_gateway_instance_name in augmented_graph.nodes_by_name

    os.makedirs(output_dir, exist_ok=True)
    os.makedirs(os.path.join(output_dir, "deployment"), exist_ok=True)
    os.makedirs(os.path.join(output_dir, "gateways"), exist_ok=True)
    os.makedirs(os.path.join(output_dir, "gateways", "src"), exist_ok=True)
    os.makedirs(os.path.join(output_dir, "gateways", "include"), exist_ok=True)

    env = Environment(
        loader=FileSystemLoader(templates_dir),
        undefined=StrictUndefined,
        trim_blocks=True,
        lstrip_blocks=True,
    )

    incoming_edges_by_node: Dict[str, List[GraphEdge]] = {}
    outgoing_edges_by_node: Dict[str, List[GraphEdge]] = {}

    for edge in augmented_graph.edges:
        if edge.dst.name not in incoming_edges_by_node:
            incoming_edges_by_node[edge.dst.name] = []
        incoming_edges_by_node[edge.dst.name].append(edge)

        if edge.src.name not in outgoing_edges_by_node:
            outgoing_edges_by_node[edge.src.name] = []
        outgoing_edges_by_node[edge.src.name].append(edge)

    input_gateway_node = augmented_graph.nodes_by_name[input_gateway_instance_name]
    output_gateway_node = augmented_graph.nodes_by_name[output_gateway_instance_name]

    gateway_instances: List[Dict[str, Any]] = [
        {
            "name": input_gateway_node.name,
            "type": input_gateway_node.type,
            "connections": [],
        },
        {
            "name": output_gateway_node.name,
            "type": output_gateway_node.type,
            "connections": [
                {
                    "from_instance": edge.src.name,
                    "from_port": edge.src_port,
                    "to_port": edge.dst_port,
                }
                for edge in incoming_edges_by_node[output_gateway_instance_name]
            ],
        },
    ]

    activity_instances: List[Dict[str, Any]] = []
    for activity_name in selected_activity_names:
        activity_node = augmented_graph.nodes_by_name[activity_name]
        activity_instances.append(
            {
                "name": activity_node.name,
                "type": activity_node.type,
                "component_name": activity_node.name[:-18],
                "connections": [
                    {
                        "from_instance": edge.src.name,
                        "from_port": edge.src_port,
                        "to_port": edge.dst_port,
                    }
                    for edge in incoming_edges_by_node[activity_name]
                ],
            }
        )


    activity_dependency_names = get_dependencies_per_activity(full_graph, selected_activity_names)
    dependency_set = set()
    for ad_list in activity_dependency_names.values():
        for ad in ad_list:
            dependency_set.add(ad["component_name"])

    for ai in activity_instances:
        dependency_set.add(ai["component_name"])


    print(activity_dependency_names)
    print(dependency_set)

    augmented_dependency_set = [
        { "component_name": dn } for dn in dependency_set
    ]

    print(augmented_dependency_set)

    augmented_dependency_types = []
    for adi in augmented_dependency_set:
        dn = adi["component_name"]
        for fgn in full_graph.nodes_by_name.values():
            if fgn.name[:-18] == dn:
                augmented_dependency_types.append({"type": fgn.type})

    print(f"{augmented_dependency_types = }")

    activity_context = {
        "gateway_instances": gateway_instances,
        "activity_instances": activity_instances,
    }

    input_gateway_output_ports: List[Dict[str, str]] = []
    seen_input_gateway_outputs: Set[Tuple[str, str]] = set()
    for edge in outgoing_edges_by_node.get(input_gateway_instance_name, []):
        key = (edge.data_type, edge.src_port)
        if key in seen_input_gateway_outputs:
            continue
        seen_input_gateway_outputs.add(key)
        input_gateway_output_ports.append(
            {
                "name": edge.src_port,
                "type": edge.data_type,
            }
        )

    input_gateway_yaml_context = {
        "gateway_class_name": input_gateway_class_name,
        "activity_instances": augmented_dependency_types,
        "input_ports": [],
        "output_ports": input_gateway_output_ports,
    }

    output_gateway_input_ports: List[Dict[str, Any]] = []
    seen_output_gateway_inputs: Set[Tuple[str, str]] = set()
    for edge in incoming_edges_by_node.get(output_gateway_instance_name, []):
        key = (edge.data_type, edge.dst_port)
        if key in seen_output_gateway_inputs:
            continue
        seen_output_gateway_inputs.add(key)
        output_gateway_input_ports.append(
            {
                "name": edge.dst_port,
                "type": edge.data_type,
                "policy": "new",
                "cache_size": 1,
            }
        )

    output_gateway_yaml_context = {
        "gateway_class_name": output_gateway_class_name,
        "activity_instances": activity_instances,
        "input_ports": output_gateway_input_ports,
        "output_ports": [],
    }

    demo_interfaces_include_dir = os.path.join(
        repo_root,
        "interfaces",
        "include",
        "demo_interfaces",
    )

    csv_file_path = os.path.join("..", f"{test_name}.csv")

    input_gateway_reader_context = build_input_gateway_reader_context(
        augmented_graph=augmented_graph,
        input_gateway_instance_name=input_gateway_instance_name,
        demo_interfaces_include_dir=demo_interfaces_include_dir,
        csv_file_path=csv_file_path,
        timestamp_field_name="timestamp_ns",
        timestamp_cpp_type="std::uint64_t",
    )

    print_csv_header_schema(input_gateway_reader_context)

    input_gateway_code_context = {
        "gateway_class_name": input_gateway_class_name,
        "activity_instances": activity_instances,
        "gateway_input_ports": [],
        "gateway_output_ports": [
            {
                "name": item["name"],
                "type": item["type"],
            }
            for item in input_gateway_output_ports
        ],
        **input_gateway_reader_context,
    }

    output_gateway_code_context = {
        "gateway_class_name": output_gateway_class_name,
        "gateway_input_ports": [
            {
                "name": item["name"],
                "type": item["type"],
            }
            for item in output_gateway_input_ports
        ],
        "gateway_output_ports": [],
    }

    deployment_context = {
        "activity_graph_import_name": f"{test_name}.activity_graph",
        "deployed_instances": [
            {
                "kind": "gateway_instance",
                "name": input_gateway_instance_name,
            },
            {
                "kind": "gateway_instance",
                "name": output_gateway_instance_name,
            },
            *[
                {
                    "kind": "activity_instance",
                    "name": activity_name,
                }
                for activity_name in selected_activity_names
            ],
        ],
    }

    application_cmake_context = {
        "test_name": test_name,
        "repo_root": os.path.join("../..", repo_root),
        "activity_instances": augmented_dependency_set,
        "activities_root": os.path.join("../..", activities_root),
    }

    gateway_cmake_context = {
        "gateways": [
            {
                "class_name": input_gateway_class_name,
            },
            {
                "class_name": output_gateway_class_name,
            },
        ],
    }

    template = env.get_template("gateway.CMakeLists.txt.j2")
    rendered = template.render(**gateway_cmake_context)
    with open(
        os.path.join(output_dir, "gateways", f"CMakeLists.txt"),
        "w",
        encoding="utf-8",
    ) as f:
        f.write(rendered)

    template = env.get_template("Application.CMakeLists.txt.j2")
    rendered = template.render(**application_cmake_context)
    with open(
        os.path.join(output_dir, f"CMakeLists.txt"),
        "w",
        encoding="utf-8",
    ) as f:
        f.write(rendered)

    template = env.get_template("activity_graph.yaml.j2")
    rendered = template.render(**activity_context)
    with open(
        os.path.join(output_dir, "deployment", f"Application.activity_graph.yaml"),
        "w",
        encoding="utf-8",
    ) as f:
        f.write(rendered)

    template = env.get_template("deploy.CMakeLists.txt.j2")
    rendered = template.render(**{"test_name": test_name})
    with open(
        os.path.join(output_dir, "deployment", f"CMakeLists.txt"),
        "w",
        encoding="utf-8",
    ) as f:
        f.write(rendered)

    template = env.get_template("input_gateway.yaml.j2")
    rendered = template.render(**input_gateway_yaml_context)
    with open(
        os.path.join(output_dir, "gateways", f"{input_gateway_class_name}.gateway.yaml"),
        "w",
        encoding="utf-8",
    ) as f:
        f.write(rendered)

    template = env.get_template("output_gateway.yaml.j2")
    rendered = template.render(**output_gateway_yaml_context)
    with open(
        os.path.join(output_dir, "gateways", f"{output_gateway_class_name}.gateway.yaml"),
        "w",
        encoding="utf-8",
    ) as f:
        f.write(rendered)

    template = env.get_template("input_gateway_impl.hpp.j2")
    rendered = template.render(**input_gateway_code_context)
    with open(
        os.path.join(
            output_dir, "gateways", "include", f"{input_gateway_class_name}Impl.hpp"
        ),
        "w",
        encoding="utf-8",
    ) as f:
        f.write(rendered)

    template = env.get_template("input_gateway_impl.cpp.j2")
    rendered = template.render(**input_gateway_code_context)
    with open(
        os.path.join(
            output_dir, "gateways", "src", f"{input_gateway_class_name}Impl.cpp"
        ),
        "w",
        encoding="utf-8",
    ) as f:
        f.write(rendered)

    template = env.get_template("output_gateway_impl.hpp.j2")
    rendered = template.render(**output_gateway_code_context)
    with open(
        os.path.join(
            output_dir, "gateways", "include", f"{output_gateway_class_name}Impl.hpp"
        ),
        "w",
        encoding="utf-8",
    ) as f:
        f.write(rendered)

    template = env.get_template("output_gateway_impl.cpp.j2")
    rendered = template.render(**output_gateway_code_context)
    with open(
        os.path.join(
            output_dir, "gateways", "src", f"{output_gateway_class_name}Impl.cpp"
        ),
        "w",
        encoding="utf-8",
    ) as f:
        f.write(rendered)

    template = env.get_template("deployment.deploy.yaml.j2")
    rendered = template.render(**deployment_context)
    with open(
        os.path.join(output_dir, "deployment", f"Deployment.deploy.yaml"),
        "w",
        encoding="utf-8",
    ) as f:
        f.write(rendered)

    import shutil

    shutil.copyfile("templates/conanfile.py", f"{output_dir}/conanfile.py")
    shutil.copyfile("templates/build.sh", f"{output_dir}/build.sh")
    shutil.copyfile("templates/run.sh", f"{output_dir}/run.sh")


def main() -> None:
    repo_root = "../../onboard/demo_application_v1/edms"
    activities_root = os.path.join(repo_root, "components")
    application_activity_path = os.path.join(
        repo_root,
        "deployment",
        "FocusDemo.activity_graph.yaml",
    )
    templates_dir = "./templates"
    output_dir = "./out"

    test_name = "my_test"

    selected_components = [
        "swc_consumer",
    ]

    selected_activity_names = [
        infer_instance_name(component_name) for component_name in selected_components
    ]

    test_name_pascal = to_pascal_case(test_name)

    input_gateway_instance_name = f"{test_name}_input_gw"
    output_gateway_instance_name = f"{test_name}_output_gw"

    input_gateway_class_name = f"{test_name_pascal}InputGw"
    output_gateway_class_name = f"{test_name_pascal}OutputGw"

    input_gateway_type = input_gateway_class_name
    output_gateway_type = output_gateway_class_name

    full_graph = build_full_graph(
        repo_root=activities_root,
        application_activity_path=application_activity_path,
    )

    subgraph = build_induced_subgraph(
        full_graph=full_graph,
        selected_activity_names=selected_activity_names,
    )

    validate_subgraph(
        full_graph=full_graph,
        subgraph=subgraph,
    )

    unconnected_inputs_by_activity = get_unconnected_input_ports_by_activity(
        full_graph=full_graph,
        subgraph=subgraph,
    )

    all_outputs_by_activity = get_all_output_ports_by_activity(
        full_graph=full_graph,
        subgraph=subgraph,
    )

    augmented_graph = build_augmented_application_graph(
        subgraph=subgraph,
        unconnected_inputs_by_activity=unconnected_inputs_by_activity,
        all_outputs_by_activity=all_outputs_by_activity,
        input_gateway_instance_name=input_gateway_instance_name,
        input_gateway_type=input_gateway_type,
        output_gateway_instance_name=output_gateway_instance_name,
        output_gateway_type=output_gateway_type,
    )

    # print_application_graph(full_graph, title="Full graph")
    # print("")
    # print_application_graph(subgraph, title="Selected subgraph")
    # print("")
    # print_application_graph(augmented_graph, title="Augmented graph")

    generate_files(
        templates_dir=templates_dir,
        repo_root=repo_root,
        activities_root=activities_root,
        output_dir=os.path.join(output_dir, f"{test_name}"),
        test_name=test_name,
        augmented_graph=augmented_graph,
        selected_activity_names=selected_activity_names,
        input_gateway_instance_name=input_gateway_instance_name,
        output_gateway_instance_name=output_gateway_instance_name,
        input_gateway_class_name=input_gateway_class_name,
        output_gateway_class_name=output_gateway_class_name,
        full_graph=full_graph,
    )


if __name__ == "__main__":
    main()
