# 把 Shaders.metal 内嵌成 Swift 字符串（打包成 .app 时不用处理资源包）
import pathlib
root = pathlib.Path(__file__).resolve().parent.parent / 'Sources/LinseCore'
src = (root / 'Shaders.metal').read_text()
assert '"""' not in src and '\\' not in src
(root / 'ShaderSource.swift').write_text('// 由 Shaders.metal 生成的内嵌源码（运行时编译）。改着色器请改 Shaders.metal 后运行 scripts/embed-shader.py\nlet shaderSource = """\n' + src + '"""\n')
