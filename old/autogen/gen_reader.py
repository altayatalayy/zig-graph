import os
import re
from dataclasses import dataclass
from typing import Dict, Iterable, List, Optional, Set, Tuple

from jinja2 import Environment, BaseLoader, StrictUndefined
from tree_sitter import Language, Parser
import tree_sitter_cpp as tscpp
from tree_sitter import Language, Parser




@dataclass(frozen=True)
class StructField:
    name: str
    cpp_type: str


@dataclass(frozen=True)
class StructInfo:
    unqualified_name: str
    fully_qualified_name: str
    namespace_name: str
    include_path: str
    fields: List[StructField]


@dataclass(frozen=True)
class InputGatewayPort:
    member_name: str
    cpp_type: str


def _make_cpp_parser() -> Parser:
    C_LANGUAGE = Language(tscpp.language(), name="cpp")
    parser = Parser()

    parser.set_language(C_LANGUAGE)
    return parser


def _node_text(source_bytes: bytes, node) -> str:
    return source_bytes[node.start_byte : node.end_byte].decode("utf-8")


def _iter_nodes_dfs(node) -> Iterable:
    yield node
    for child in node.children:
        for nested in _iter_nodes_dfs(child):
            yield nested


def _canonicalize_cpp_type(value: str) -> str:
    result = value.strip()
    result = re.sub(r"\s+", " ", result)
    result = re.sub(r"\s*::\s*", "::", result)
    result = re.sub(r"\s*<\s*", "<", result)
    result = re.sub(r"\s*>\s*", ">", result)
    result = re.sub(r"\s*,\s*", ", ", result)
    return result


def _extract_primary_namespace(file_text: str) -> str:
    match = re.search(r"\bnamespace\s+([A-Za-z_]\w*(?:::\w+)*)\s*\{", file_text)
    if match is None:
        return ""
    return match.group(1)


def _is_supported_arithmetic_type(cpp_type: str) -> bool:
    normalized = cpp_type.strip().replace("std::", "")

    supported = {
        "bool",
        "char",
        "signed char",
        "unsigned char",
        "short",
        "unsigned short",
        "int",
        "unsigned int",
        "long",
        "unsigned long",
        "long long",
        "unsigned long long",
        "float",
        "double",
        "long double",
        "int8_t",
        "uint8_t",
        "int16_t",
        "uint16_t",
        "int32_t",
        "uint32_t",
        "int64_t",
        "uint64_t",
        "size_t",
    }

    return normalized in supported


def _parse_field_declaration_text(field_text: str) -> StructField:
    text = re.sub(r"//.*", "", field_text).strip()
    text = _canonicalize_cpp_type(text)

    if "," in text:
        raise ValueError(
            "Comma-separated field declarations are not supported: {}".format(text)
        )
    if "=" in text:
        raise ValueError(
            "Default-initialized struct fields are not supported: {}".format(text)
        )
    if "[" in text or "]" in text:
        raise ValueError("Array fields are not supported: {}".format(text))
    if "(" in text or ")" in text:
        raise ValueError(
            "Function-pointer-like fields are not supported: {}".format(text)
        )

    match = re.match(
        r"^(?P<type>.+?)\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*;\s*$",
        text,
    )
    if match is None:
        raise ValueError("Could not parse field declaration: {}".format(text))

    cpp_type = _canonicalize_cpp_type(match.group("type"))
    field_name = match.group("name")

    if not _is_supported_arithmetic_type(cpp_type):
        raise ValueError(
            "Unsupported field type '{}'. Only arithmetic scalar fields are supported.".format(
                cpp_type
            )
        )

    return StructField(name=field_name, cpp_type=cpp_type)


def parse_structs_from_header(
    header_path: str,
    include_root: str,
    parser: Parser,
) -> List[StructInfo]:
    with open(header_path, "rb") as f:
        source_bytes = f.read()

    file_text = source_bytes.decode("utf-8")
    tree = parser.parse(source_bytes)

    namespace_name = _extract_primary_namespace(file_text)
    relative_include = os.path.relpath(header_path, include_root).replace(os.sep, "/")

    structs: List[StructInfo] = []

    for node in _iter_nodes_dfs(tree.root_node):
        if node.type != "struct_specifier":
            continue

        struct_text = _node_text(source_bytes, node)
        name_match = re.search(r"\bstruct\s+([A-Za-z_][A-Za-z0-9_]*)", struct_text)
        if name_match is None:
            continue

        struct_name = name_match.group(1)

        field_list_node = None
        for child in node.children:
            if child.type == "field_declaration_list":
                field_list_node = child
                break

        if field_list_node is None:
            continue

        fields: List[StructField] = []
        field_nodes = getattr(field_list_node, "named_children", None)
        if field_nodes is None:
            field_nodes = field_list_node.children

        for field_node in field_nodes:
            if field_node.type != "field_declaration":
                continue
            field_text = _node_text(source_bytes, field_node)
            fields.append(_parse_field_declaration_text(field_text))

        fully_qualified_name = (
            "{}::{}".format(namespace_name, struct_name)
            if namespace_name
            else struct_name
        )

        structs.append(
            StructInfo(
                unqualified_name=struct_name,
                fully_qualified_name=fully_qualified_name,
                namespace_name=namespace_name,
                include_path=relative_include,
                fields=fields,
            )
        )

    return structs


def build_struct_index(demo_interfaces_include_dir: str) -> Dict[str, StructInfo]:
    if not os.path.isdir(demo_interfaces_include_dir):
        raise RuntimeError(
            "demo_interfaces include directory does not exist: {}".format(
                demo_interfaces_include_dir
            )
        )

    include_root = os.path.dirname(demo_interfaces_include_dir)
    parser = _make_cpp_parser()

    fq_index: Dict[str, StructInfo] = {}
    short_index: Dict[str, StructInfo] = {}

    for root, _, files in os.walk(demo_interfaces_include_dir):
        for filename in files:
            if not filename.endswith(".hpp"):
                continue

            header_path = os.path.join(root, filename)
            structs = parse_structs_from_header(
                header_path=header_path,
                include_root=include_root,
                parser=parser,
            )

            for struct_info in structs:
                if struct_info.fully_qualified_name in fq_index:
                    raise RuntimeError(
                        "Duplicate fully-qualified struct name found: {}".format(
                            struct_info.fully_qualified_name
                        )
                    )
                fq_index[struct_info.fully_qualified_name] = struct_info

                if struct_info.unqualified_name in short_index:
                    raise RuntimeError(
                        "Duplicate unqualified struct name found: {}. "
                        "Use fully-qualified type names in edge.data_type.".format(
                            struct_info.unqualified_name
                        )
                    )
                short_index[struct_info.unqualified_name] = struct_info

    result: Dict[str, StructInfo] = {}
    result.update(fq_index)
    result.update(short_index)
    return result


def collect_input_gateway_ports(
    augmented_graph,
    input_gateway_instance_name: str,
) -> List[InputGatewayPort]:
    if input_gateway_instance_name not in augmented_graph.nodes_by_name:
        raise RuntimeError(
            "Input gateway '{}' not found in augmented graph".format(
                input_gateway_instance_name
            )
        )

    node = augmented_graph.nodes_by_name[input_gateway_instance_name]
    if node.kind != "gateway":
        raise RuntimeError(
            "Node '{}' is not a gateway".format(input_gateway_instance_name)
        )

    port_types_by_name: Dict[str, str] = {}

    for edge in augmented_graph.edges:
        if edge.src.name != input_gateway_instance_name:
            continue

        member_name = edge.src_port.strip()
        cpp_type = edge.data_type.strip()

        if member_name in port_types_by_name:
            if port_types_by_name[member_name] != cpp_type:
                raise RuntimeError(
                    "Type mismatch for input gateway port '{}': '{}' vs '{}'".format(
                        member_name,
                        port_types_by_name[member_name],
                        cpp_type,
                    )
                )
        else:
            port_types_by_name[member_name] = cpp_type

    ports = [
        InputGatewayPort(member_name=name, cpp_type=port_types_by_name[name])
        for name in sorted(port_types_by_name.keys())
    ]

    if not ports:
        raise RuntimeError(
            "No outgoing ports found on input gateway '{}'".format(
                input_gateway_instance_name
            )
        )

    return ports


def resolve_struct_info(
    struct_index: Dict[str, StructInfo],
    cpp_type_name: str,
) -> StructInfo:
    key = _canonicalize_cpp_type(cpp_type_name)

    if key in struct_index:
        return struct_index[key]

    key_without_std = key.replace("std::", "")
    if key_without_std in struct_index:
        return struct_index[key_without_std]

    raise RuntimeError(
        "Could not resolve struct type '{}' from demo_interfaces headers".format(
            cpp_type_name
        )
    )


def build_input_gateway_reader_context(
    augmented_graph,
    input_gateway_instance_name: str,
    demo_interfaces_include_dir: str,
    csv_file_path: str,
    timestamp_field_name: str = "timestamp_ns",
    timestamp_cpp_type: str = "std::uint64_t",
) -> Dict[str, object]:
    struct_index = build_struct_index(demo_interfaces_include_dir)
    input_ports = collect_input_gateway_ports(
        augmented_graph=augmented_graph,
        input_gateway_instance_name=input_gateway_instance_name,
    )

    struct_includes_set: Set[str] = set()
    csv_columns: List[str] = ["timestamp"]
    step_members: List[Dict[str, object]] = []

    next_column_index = 1

    for port in input_ports:
        struct_info = resolve_struct_info(struct_index, port.cpp_type)
        struct_includes_set.add(struct_info.include_path)

        member_fields: List[Dict[str, object]] = []
        for field in struct_info.fields:
            csv_column_name = "{}.{}".format(port.member_name, field.name)
            csv_columns.append(csv_column_name)

            member_fields.append(
                {
                    "name": field.name,
                    "cpp_type": field.cpp_type,
                    "csv_column_name": csv_column_name,
                    "column_index": next_column_index,
                }
            )
            next_column_index += 1

        step_members.append(
            {
                "member_name": port.member_name,
                "cpp_type": struct_info.fully_qualified_name,
                "fields": member_fields,
            }
        )

    return {
        "csv_file_path": csv_file_path,
        "timestamp_field_name": timestamp_field_name,
        "timestamp_cpp_type": timestamp_cpp_type,
        "csv_columns": csv_columns,
        "step_members": step_members,
        "struct_includes": sorted(struct_includes_set),
    }


def print_csv_header_schema(reader_context: Dict[str, object]) -> None:
    print("CSV header schema:")
    print(",".join(reader_context["csv_columns"]))
    print("")
