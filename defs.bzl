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
    """无依赖的JSON序列化实现，支持Bazel Struct/字典/列表/基础类型 (无isinstance版本)"""
    # 优先处理可序列化对象
    if hasattr(obj, "to_dict"):
        obj = obj.to_dict()
    elif hasattr(obj, "to_json"):
        return obj.to_json()

    # 处理Bazel Struct类型（通过dir()获取属性并转为字典）
    # 注意：检查 to_proto 是一个常见的技巧，但不是绝对保证。
    # 如果struct没有to_proto但你想序列化，可能需要其他检查。
    if hasattr(obj, "to_proto"):
        # 过滤掉私有属性和方法，只保留看起来像字段的
        obj_dict = {}
        for k in dir(obj):
            # 简单的过滤，避免方法或私有属性
            # 使用 getattr 获取值，然后检查是否可调用
            val = getattr(obj, k)
            if not k.startswith("_") and not callable(val):
                 obj_dict[k] = val # 使用获取到的值
        obj = obj_dict # 使用过滤后的字典进行序列化


    # 处理字典类型（检查items()方法）
    if hasattr(obj, "items"):
        items = [
            "\"%s\": %s" % (k, _custom_json_encode(v, indent))
            for k, v in obj.items()
        ]
        if indent:
            # 使用列表推导式和join构建缩进字符串
            inner_items = ["\n" + indent + "  " + i for i in items]
            return "{" + "".join(inner_items) + "\n" + indent + "}" if items else "{}"
        else:
            return "{%s}" % ", ".join(items)

    # 处理列表/元组/depset类型（检查__iter__且非字符串）
    # 使用 type(obj) == type("") 替代 isinstance(obj, str)
    elif hasattr(obj, "__iter__") and not (type(obj) == type("")):
        items = [_custom_json_encode(v, indent) for v in obj]
        if indent:
            # 使用列表推导式和join构建缩进字符串
            inner_items = ["\n" + indent + "  " + i for i in items]
            return "[" + "".join(inner_items) + "\n" + indent + "]" if items else "[]"
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
    # 这个检查对于负数和浮点数是有效的
    elif str(obj).lstrip("-").replace(".", "", 1).isdigit():
        return str(obj)
    # 其他类型视为字符串（包含转义处理）
    else:
        # 确保先转换为字符串，再进行替换
        s = str(obj)
        # 基本的JSON字符串转义
        s = s.replace("\\", "\\\\") # 先替换反斜杠
        s = s.replace("\"", "\\\"") # 再替换双引号
        s = s.replace("\n", "\\n")  # 换行符
        s = s.replace("\r", "\\r")  # 回车符
        s = s.replace("\t", "\\t")  # 制表符
        # 可以根据需要添加更多转义，例如 \b, \f
        return "\"%s\"" % s


def _compilation_database_impl(ctx):
    # Generates a single compile_commands.json file with the
    # transitive depset of specified targets.

    if ctx.attr.disable:
        ctx.actions.write(output = ctx.outputs.filename, content = "[]\n")
        return [] # 确保返回列表

    compilation_db_list = []
    all_headers_list = []
    for target in ctx.attr.targets:
        # 检查是否存在 CompilationAspect 和 OutputGroupInfo
        if CompilationAspect in target:
             compilation_db_list.append(target[CompilationAspect].compilation_db)
        if OutputGroupInfo in target:
             all_headers_list.append(target[OutputGroupInfo].header_files)

    compilation_db = depset(transitive = compilation_db_list)
    all_headers = depset(transitive = all_headers_list)

    # 确保 exec_root 的路径分隔符是 /
    exec_root = (ctx.attr.output_base + "/execroot/" + ctx.workspace_name).replace("\\", "/")

    # 将 depset 转换为列表进行处理
    content_list = compilation_db.to_list()

    # 使用字典进行去重（如果启用了 unique）
    if ctx.attr.unique:
        # 确保 element.file 存在且是字符串
        unique_elements = {}
        for element in content_list:
             if hasattr(element, "file") and type(element.file) == type(""):
                  unique_elements[element.file] = element
        content_list = unique_elements.values() # 获取去重后的值列表

    # 使用自定义JSON编码器，并启用缩进以提高可读性
    # 注意：如果你不需要缩进，可以将 indent="" 或 None 传递给 _custom_json_encode
    # 为了生成标准的 compile_commands.json，通常需要缩进
    content_json = _custom_json_encode(content_list, indent="") # 传递空字符串作为初始缩进

    # 进行路径替换
    # 为确保替换准确，可以在 exec_root 前后添加标记或确保其唯一性
    # 这里的简单替换可能在某些边缘情况下出问题，但通常是有效的
    content_json = content_json.replace("__EXEC_ROOT__", exec_root)
    content_json = content_json.replace("-isysroot __BAZEL_XCODE_SDKROOT__", "")

    # 添加末尾换行符
    ctx.actions.write(output = ctx.outputs.filename, content = content_json + "\n")

    return [
        OutputGroupInfo(
            # 提供 header 文件作为默认输出组的一部分可能不是标准做法
            # 通常 compile_commands.json 本身是主要输出
            # 如果确实需要，保留此行
            # default = all_headers,
            # 可以考虑创建一个专门的输出组给头文件
            header_files = all_headers,
        ),
    ]

_compilation_database = rule(
    attrs = {
        "targets": attr.label_list(
            aspects = [compilation_database_aspect],
            doc = "List of all cc targets which should be included.",
        ),
        "output_base": attr.string(
            # 使用 $(output_base) 让Bazel自动填充
            default = "$(output_base)",
            doc = ("Output base of Bazel. Use $(output_base) for automatic expansion. " +
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
            mandatory = True, # 通常输出文件名是必须的
            doc = "Name of the generated compilation database (e.g., compile_commands.json).",
        ),
    },
    implementation = _compilation_database_impl,
    # 声明此规则产生一个输出文件
    outputs = {"filename": "%{name}"}, # 默认输出文件名与规则名相同
)

def compilation_database(name, filename = "compile_commands.json", **kwargs):
    # 如果 filename 不是默认值，覆盖默认的 outputs 映射
    output_map = {"filename": filename} if filename != "%{name}" else None

    _compilation_database(
        name = name,
        # filename 属性现在由 rule 的 outputs 处理，这里不需要传递
        # filename = filename, # 移除这行
        outputs = output_map, # 如果需要自定义输出名，则传递 output_map
        **kwargs
    )