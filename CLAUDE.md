# Tracy MCP Server

An MCP (Model Context Protocol) server for analyzing Tracy profiler captures, enabling Claude to help with Julia program performance analysis.

## Project Structure

```
TracyMCP/
├── Project.toml          # Package manifest with [apps] section
├── src/
│   ├── TracyMCP.jl       # Main module, MCP server, @main entry point
│   ├── TracyReader.jl    # Binary file parser (includes types.jl, decompression.jl)
│   ├── types.jl          # Data structures (TracyTrace, ZoneEvent, etc.)
│   ├── decompression.jl  # LZ4/ZSTD block decompression, LEB128 encoding
│   └── tools/
│       └── trace_tools.jl # MCP tool implementations
└── test/
    └── runtests.jl       # Unit and integration tests
```

## Development Commands

```bash
# Run tests
julia --project=. -e 'using Pkg; Pkg.test()'

# Load module interactively
julia --project=. -e 'using TracyMCP'

# Quick trace analysis (without MCP)
julia --project=. -e 'using TracyMCP; TracyMCP.load_and_analyze("file.tracy")'

# Install as app (after committing changes)
julia -e 'using Pkg; Pkg.Apps.add(path=".")'

# Run installed app
tracy-mcp --help
tracy-mcp analyze file.tracy
```

## Key Technical Details

### Tracy Binary Format

Tracy files use a packet-based format with:
- **Block compression**: LZ4 or ZSTD in 64KB blocks (4-byte size prefix + compressed data)
- **Delta encoding**: Timestamps stored as differences from previous values
- **LEB128 encoding**: Variable-length integers for compact storage
- **String table**: Pointers reference strings stored separately

### Important Opcodes (in `TracyReader.jl`)

- `0x10` ZoneBegin, `0x12` ZoneEnd - CPU profiling zones
- `0x03` SourceLocation - file/line/function info
- `0x02` ThreadName - thread identification
- `0x30`/`0x31` MemAlloc/MemFree - memory tracking
- `0x50` Message - log messages

### MCP Tools Available

| Tool | Purpose |
|------|---------|
| `load_trace` | Load a .tracy file (required first) |
| `get_trace_summary` | Overview statistics |
| `find_hotspots` | Find slowest zones by time/count |
| `analyze_function` | Analyze specific function by pattern |
| `get_zone_tree` | Hierarchical zone view |
| `search_zones` | Search zones by name |
| `get_memory_summary` | Memory allocation stats |
| `get_thread_timeline` | Timeline of zone activity |
| `get_messages` | Log messages from trace |

## Dependencies

- `ModelContextProtocol.jl` - MCP server framework
- `CodecLz4.jl` / `CodecZstd.jl` - Decompression
- `JSON3.jl` - JSON serialization
- `TranscodingStreams.jl` - Stream processing

## Known Limitations

1. **File format complexity**: Tracy's binary format evolves with each version. The parser implements common opcodes but may need updates for newer Tracy versions.

2. **No GPU zones**: GPU profiling data is not yet parsed (Phase 2).

3. **Approximate self-time**: Self-time calculation is approximate; proper calculation requires building the full call tree.

## Testing with Real Files

To test with actual Tracy captures:
1. Profile a Julia program using TracyProfiler.jl
2. Save the capture as a .tracy file
3. Use `tracy-mcp analyze file.tracy` or load via MCP tools

## Architecture Notes

- Global state (`CURRENT_TRACE`, `CURRENT_FILE`) holds the loaded trace for tool access
- Tools return JSON strings for MCP compatibility
- The `@main` function in TracyMCP.jl enables Pkg app support (Julia 1.12+)
