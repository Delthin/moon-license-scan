# SPDX 标识数据

本工具使用 SPDX License List 3.29.0 校验源文件中的显式声明。标识及弃用状态来自 [EmbarkStudios/spdx 0.13.6 的 identifiers.rs](https://github.com/EmbarkStudios/spdx/blob/0ca398c29698ee46c9d2497569817aebde53feaf/src/identifiers.rs)，其项目按 [Apache-2.0](https://github.com/EmbarkStudios/spdx/blob/0ca398c29698ee46c9d2497569817aebde53feaf/LICENSE-APACHE) 授权。这里仅保留许可和例外的标识及弃用状态，并重排为 MoonBit 查询表；没有引入 Rust 源码作为运行时依赖，也未复制其中引用的许可证正文。

重新生成时下载上述固定提交的原始文件（SHA-256：`6e8592e4c7d6ea98813fa1ab31662a26461f08be2bf155453c5191fc1005d376`），在仓库根目录执行：

```sh
moon run --target native spdx-sources/generate.mbtx -- /path/to/identifiers.rs > src/spdx_catalog/identifiers.mbt
moon fmt src/spdx_catalog
```

生成器会核对输入摘要和记录数量。使用者无需下载或生成此表。
