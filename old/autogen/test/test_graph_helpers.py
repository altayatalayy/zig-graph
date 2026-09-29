from graph_helpers import (
    ApplicationGraph,
    GraphEdge,
    GraphNode,
    build_induced_subgraph,
    get_all_output_ports_by_activity,
    get_unconnected_input_ports_by_activity,
    validate_subgraph,
)


def build_sample_full_graph() -> ApplicationGraph:
    ext_in_gw = GraphNode(name="ext_in_gw", type="ExtInGw", kind="gateway")
    comp_a = GraphNode(name="comp_a_activity_instance", type="CompA", kind="activity")
    comp_b = GraphNode(name="comp_b_activity_instance", type="CompB", kind="activity")
    comp_c = GraphNode(name="comp_c_activity_instance", type="CompC", kind="activity")

    nodes_by_name = {
        ext_in_gw.name: ext_in_gw,
        comp_a.name: comp_a,
        comp_b.name: comp_b,
        comp_c.name: comp_c,
    }

    edges = [
        GraphEdge(src=ext_in_gw, src_port="vehicle_speed", dst=comp_a, dst_port="vehicle_speed_input", data_type="VehicleSpeed"),
        GraphEdge(src=ext_in_gw, src_port="target_speed", dst=comp_a, dst_port="target_speed_input", data_type="TargetSpeed"),
        GraphEdge(src=comp_a, src_port="acc_cmd_output", dst=comp_b, dst_port="acc_cmd_input", data_type="AccCmd"),
        GraphEdge(src=ext_in_gw, src_port="road_grade", dst=comp_b, dst_port="road_grade_input", data_type="RoadGrade"),
        GraphEdge(src=comp_b, src_port="torque_req_output", dst=comp_c, dst_port="torque_req_input", data_type="TorqueReq"),
        GraphEdge(src=ext_in_gw, src_port="driver_override", dst=comp_c, dst_port="driver_override_input", data_type="DriverOverride"),
    ]

    return ApplicationGraph(nodes_by_name=nodes_by_name, edges=edges)


def test_build_induced_subgraph_with_one_activity() -> None:
    full_graph = build_sample_full_graph()
    subgraph = build_induced_subgraph(full_graph, ["comp_a_activity_instance"])
    assert set(subgraph.nodes_by_name.keys()) == {"comp_a_activity_instance"}
    assert len(subgraph.edges) == 0


def test_build_induced_subgraph_with_two_activities() -> None:
    full_graph = build_sample_full_graph()
    subgraph = build_induced_subgraph(full_graph, ["comp_a_activity_instance", "comp_b_activity_instance"])
    assert set(subgraph.nodes_by_name.keys()) == {"comp_a_activity_instance", "comp_b_activity_instance"}
    assert len(subgraph.edges) == 1
    edge = subgraph.edges[0]
    assert edge.src.name == "comp_a_activity_instance"
    assert edge.src_port == "acc_cmd_output"
    assert edge.dst.name == "comp_b_activity_instance"
    assert edge.dst_port == "acc_cmd_input"
    assert edge.data_type == "AccCmd"


def test_validate_subgraph() -> None:
    full_graph = build_sample_full_graph()
    subgraph = build_induced_subgraph(full_graph, ["comp_a_activity_instance", "comp_b_activity_instance"])
    validate_subgraph(full_graph, subgraph)


def test_get_all_output_ports_by_activity() -> None:
    full_graph = build_sample_full_graph()
    subgraph = build_induced_subgraph(full_graph, ["comp_a_activity_instance", "comp_b_activity_instance"])
    outputs = get_all_output_ports_by_activity(full_graph, subgraph)
    assert outputs == {
        "comp_a_activity_instance": [("AccCmd", "acc_cmd_output")],
        "comp_b_activity_instance": [("TorqueReq", "torque_req_output")],
    }


def test_get_unconnected_input_ports_by_activity() -> None:
    full_graph = build_sample_full_graph()
    subgraph = build_induced_subgraph(full_graph, ["comp_a_activity_instance", "comp_b_activity_instance"])
    unconnected = get_unconnected_input_ports_by_activity(full_graph, subgraph)
    assert unconnected == {
        "comp_a_activity_instance": [
            ("VehicleSpeed", "vehicle_speed_input"),
            ("TargetSpeed", "target_speed_input"),
        ],
        "comp_b_activity_instance": [
            ("RoadGrade", "road_grade_input"),
        ],
    }
