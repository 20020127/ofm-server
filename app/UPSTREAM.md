# 来源与溯源

本目录由 tools/build-app.mjs 自动生成，请勿手工编辑（重新生成会覆盖）。

- 上游项目：Ebony-Vinyl/dsh-our-free-model（MIT License）
- 上游版本：dsh-our-free-model@2.1.0；standalone 包版本 0.1.0
- 上游地址：https://github.com/Ebony-Vinyl/dsh-our-free-model
- 提取内容：packages/standalone 运行时闭包 + src/ 核心 + vendor/channel-pack 资产 + web/ 预构建前端
- 路径改写：packages/standalone 的深层相对导入（../../src、../../../vendor）已扁平化为 ../src、../vendor
- 密钥脱敏：上游内置的 4 处第三方硬编码凭据已替换为环境变量覆盖（见 docs/COMPLIANCE.md 第 1b 节）
- 运行时依赖：无（仅 Node.js 内置模块，engines: "^22.19.0 || >=24.0.0"）

上游 LICENSE 见本目录 LICENSE 文件，保留其版权声明即满足 MIT 要求。
