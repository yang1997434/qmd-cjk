[English](README.md) | [中文](README.zh-CN.md)

# qmd-cjk

为 [qmd](https://github.com/tobi/qmd) 添加中日韩 + 拼音全文搜索能力。

qmd 默认的 FTS5 tokenizer（`porter unicode61`）不切分 CJK 字符 — 整段中文被当成一个 token，所以 `节点扩容` 这种查询永远 0 命中。qmd-cjk 通过 patch qmd 让它在启动时加载 [wangfenjin/simple](https://github.com/wangfenjin/simple) SQLite FTS5 扩展，并把查询包裹 `simple_query()`。安装后中文和英文都能在 ~0.3 秒内命中。

## 安装

```bash
curl -sSL https://raw.githubusercontent.com/yang1997434/qmd-cjk/main/install.sh | bash
```

或者 clone 后再装（推荐先读一遍脚本）：

```bash
git clone https://github.com/yang1997434/qmd-cjk.git
cd qmd-cjk
bash install.sh
```

国内访问 `github.com` 慢的话用镜像：

```bash
GITHUB_PROXY=ghproxy.com bash install.sh
```

## 做了什么

1. 检测 OS + glibc 版本，选 [wangfenjin/simple Releases](https://github.com/wangfenjin/simple/releases) 里对应的预编译 `libsimple`
2. 把 `libsimple.so`/`libsimple.dylib` + `dict/` 放到 `~/.local/lib/qmd/`
3. patch `@tobilu/qmd` 的 `store.ts`（5 处修改，幂等，带 backup）
4. 用 `tokenize='simple'` 重建所有 qmd 缓存索引的 `documents_fts` 表
5. 跑中英文 smoke test

## 验证

```bash
qmd search '节点扩容' --files       # 中文短语，~0.3 秒
qmd search 'hermes 节点' --files    # 中英混合
qmd search 'database'  --files     # 纯英文
```

## 平台支持

| 平台 | glibc | 状态 |
|------|-------|------|
| Linux x86_64 | ≥ 2.32 | ✅ 已测（Debian 12）|
| Linux x86_64 | ≥ 2.38 | ✅ 用 ubuntu-latest 版本 |
| Linux aarch64 | ≥ 2.38 | ✅ ubuntu-24.04-arm 版本 |
| macOS arm64 | n/a | ✅ |
| macOS x86_64 | n/a | ✅ |
| Linux glibc < 2.32 | — | ❌ 需从源码重 build libsimple |

## qmd 升级后

`@tobilu/qmd` 从 npm 升级后会覆盖 patch，中文搜索会失效。重跑 installer 即可：

```bash
bash install.sh   # 幂等 — 检测到未 patch 的 store.ts 会自动重 apply
```

判定依据：`store.ts` 里是否存在 `loadSimpleJiebaIfAvailable` 标识函数。

## 卸载

```bash
# 1. 从 backup 还原 store.ts
BACKUP=$(ls -t ~/.nvm/versions/node/*/lib/node_modules/@tobilu/qmd/src/store.ts.pre-qmd-cjk-* | head -1)
cp "$BACKUP" "${BACKUP%.pre-qmd-cjk-*}.ts"

# 2. 删除 libsimple + dict
rm -rf ~/.local/lib/qmd

# 3. qmd 下次写入时会自动重建用默认 tokenizer 的 FTS
```

## 实现原理

5 处 patch 的详细说明 + 为什么不用 SQLite `trigram` 或者应用层 jieba wrapper，见 [docs/architecture.md](docs/architecture.md)。

## License

MIT。仓库本身不打包 upstream 二进制 — `libsimple` 在 install 时从 wangfenjin/simple 下载，对方也是 MIT。

## 致谢

- [wangfenjin/simple](https://github.com/wangfenjin/simple) — 实际干活的 SQLite 扩展（jieba 分词 + 拼音搜索）
- [tobi/qmd](https://github.com/tobi/qmd) — 被 patch 的 markdown 搜索工具
