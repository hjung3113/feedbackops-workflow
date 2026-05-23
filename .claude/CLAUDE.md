## CodeGraph (optional here)

A CodeGraph MCP server (`codegraph_*` tools) is configured in `.mcp.json`. CodeGraph is a tree-sitter symbol graph — most useful in large typed codebases. **This repo is mostly bash + Markdown + JSON, so codegraph adds little value here**; prefer plain `grep`/`Read`. The server is kept configured only because this toolkit is run *against* target projects where codegraph is valuable.

If you do initialize it (`codegraph init -i`) the `.codegraph/` index is gitignored.
