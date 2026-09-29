import os

from main import (
    build_augmented_application_graph,
    build_full_graph,
    generate_files,
    get_all_output_ports_by_activity,
    get_unconnected_input_ports_by_activity,
    infer_instance_name,
    to_pascal_case,
    build_induced_subgraph,
    validate_subgraph,
)


def read_text(path: str) -> str:
    with open(path, "r", encoding="utf-8") as f:
        return f.read().strip()


def run_case(selected_components, tmp_path):
    project_root = os.path.dirname(os.path.dirname(__file__))
    repo_root = os.path.join(project_root, "test", "data", "repo")
    templates_dir = os.path.join(project_root, "templates")
    output_dir = str(tmp_path)

    test_name = "my_test"
    selected_activity_names = [infer_instance_name(component_name) for component_name in selected_components]
    test_name_pascal = to_pascal_case(test_name)

    input_gateway_instance_name = f"{test_name}_input_gw"
    output_gateway_instance_name = f"{test_name}_output_gw"
    input_gateway_class_name = f"{test_name_pascal}InputGw"
    output_gateway_class_name = f"{test_name_pascal}OutputGw"

    full_graph = build_full_graph(
        repo_root=repo_root,
        application_activity_path=os.path.join(repo_root, "application", "deployment", "Application.activity_graph.yaml"),
    )

    subgraph = build_induced_subgraph(full_graph, selected_activity_names)
    validate_subgraph(full_graph, subgraph)

    unconnected_inputs = get_unconnected_input_ports_by_activity(full_graph, subgraph)
    all_outputs = get_all_output_ports_by_activity(full_graph, subgraph)

    augmented_graph = build_augmented_application_graph(
        subgraph=subgraph,
        unconnected_inputs_by_activity=unconnected_inputs,
        all_outputs_by_activity=all_outputs,
        input_gateway_instance_name=input_gateway_instance_name,
        input_gateway_type=input_gateway_class_name,
        output_gateway_instance_name=output_gateway_instance_name,
        output_gateway_type=output_gateway_class_name,
    )

    generate_files(
        templates_dir=templates_dir,
        output_dir=output_dir,
        test_name=test_name,
        augmented_graph=augmented_graph,
        selected_activity_names=selected_activity_names,
        input_gateway_instance_name=input_gateway_instance_name,
        output_gateway_instance_name=output_gateway_instance_name,
        input_gateway_class_name=input_gateway_class_name,
        output_gateway_class_name=output_gateway_class_name,
    )

    return output_dir


def test_generate_with_one_component(tmp_path) -> None:
    project_root = os.path.dirname(os.path.dirname(__file__))
    expected_dir = os.path.join(project_root, "test", "expected", "one_component")
    output_dir = run_case(["comp_a"], tmp_path)

    expected_files = sorted(os.listdir(expected_dir))
    generated_files = sorted(os.listdir(output_dir))

    assert generated_files == expected_files

    for filename in expected_files:
        assert read_text(os.path.join(output_dir, filename)) == read_text(os.path.join(expected_dir, filename))


def test_generate_with_two_components(tmp_path) -> None:
    project_root = os.path.dirname(os.path.dirname(__file__))
    expected_dir = os.path.join(project_root, "test", "expected", "two_components")
    output_dir = run_case(["comp_a", "comp_b"], tmp_path)

    expected_files = sorted(os.listdir(expected_dir))
    generated_files = sorted(os.listdir(output_dir))

    assert generated_files == expected_files

    for filename in expected_files:
        assert read_text(os.path.join(output_dir, filename)) == read_text(os.path.join(expected_dir, filename))
