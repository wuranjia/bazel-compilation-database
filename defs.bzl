# Copyright 2024 The Bazel Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

load("@rules_compdb//:aspects.bzl", "CompilationAspect", "compilation_database_aspect")

def _custom_json_encode(obj, indent=None):
    """无依赖的JSON序列化实现，支持Bazel Struct/字典/列表/基础类型"""
    # 优先处理可序列化对象
    if hasattr(obj, "to_dict"):  
        obj = obj.to_dict()
    elif hasattr(obj, "to_json"):  
        return obj.to_json()
    
    # 处理Bazel Struct类型（通过dir()获取属性并转为字典）
    if hasattr(obj, "to_proto"):  # Bazel struct的独有特征[3](@ref)
        obj = {k: getattr(obj, k) for k in dir(obj)}
    
    # 处理字典类型（检查items()方法）
    if hasattr(obj, "items"):    
        items = [
            "\"%s\": %s" % (k, _custom_json_encode(v, indent))
            for k, v in obj.items()
        ]
        if indent:
            inner = ",\n".join([indent + "  " + i for i in items])
            return "{\n%s\n%s}" % (inner, indent)
        else:
            return "{%s}" % ", ".join(items)
    # 处理列表类型（检查__iter__且非字符串）
    elif hasattr(obj, "__iter__") and not (hasattr(obj, "strip") and isinstance(obj, str)):  
        items = [_custom_json_encode(v, indent) for v in obj]
        if indent:
            inner = ",\n".join([indent + "  " + i for i in items])
            return "[\n%s\n%s]" % (inner, indent)
        else:
            return "[%s]" % ", ".join(items)
    # 处理布尔值（通过直接值判断）
    elif obj is True:  
        return "true"
    elif obj is False:
        return "false"
    # 处理None
    elif obj is None:            
        return "null"
    # 处理数字类型（检查int/float的字符串形式）
    elif str(obj).lstrip("-").replace(".", "", 1).isdigit():  
        return str(obj)
    # 其他类型视为字符串（包含转义处理）
    else:                        
        return "\"%s\"" % str(obj).replace("\\", "\\\\").replace("\"", "\\\"")

def _compilation_database_impl(ctx):
    # Generates a single compile_commands.json file with the
    # transitive depset of specified targets.

    if ctx.attr.disable:
        ctx.actions.write(output = ctx.outputs.filename, content = "[]\n")
        return

    compilation_db = []
    all_headers = []
    for target in ctx.attr.targets:
        compilation_db.append(target[CompilationAspect].compilation_db)
        all_headers.append(target[OutputGroupInfo].header_files)

    compilation_db = depset(transitive = compilation_db)

    all_headers = depset(transitive = all_headers)

    exec_root = ctx.attr.output_base + "/execroot/" + ctx.workspace_name

    content = compilation_db.to_list()
    if ctx.attr.unique:
        content = list({element.file: element for element in content}.values())
    content = _custom_json_encode(content)
    content = content.replace("__EXEC_ROOT__", exec_root)
    content = content.replace("-isysroot __BAZEL_XCODE_SDKROOT__", "")
    ctx.actions.write(output = ctx.outputs.filename, content = content)

    return [
        OutputGroupInfo(
            default = all_headers,
        ),
    ]

_compilation_database = rule(
    attrs = {
        "targets": attr.label_list(
            aspects = [compilation_database_aspect],
            doc = "List of all cc targets which should be included.",
        ),
        "output_base": attr.string(
            default = "__OUTPUT_BASE__",
            doc = ("Output base of Bazel as returned by 'bazel info output_base'. " +
                   "The exec_root is constructed from the output_base as " +
                   "output_base + '/execroot/' + workspace_name. "),
        ),
        "disable": attr.bool(
            default = False,
            doc = ("Makes this operation a no-op; useful in combination with a 'select' " +
                   "for platforms where the internals of this rule are not properly " +
                   "supported."),
        ),
        "unique": attr.bool(
            default = True,
            doc = ("Remove duplicate entries before writing the database, reducing file size " +
                   "and potentially being faster."),
        ),
        "filename": attr.output(
            doc = "Name of the generated compilation database.",
        ),
    },
    implementation = _compilation_database_impl,
)

def compilation_database(**kwargs):
    _compilation_database(
        filename = kwargs.pop("filename", "compile_commands.json"),
        **kwargs
    )
