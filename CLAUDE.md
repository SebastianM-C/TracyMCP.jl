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
│   ├── decompression.jl  # Multi-stream ZSTD decompression
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

# Install as app (after changes)
julia -e 'using Pkg; Pkg.Apps.add(path=".")'

# Run installed app
tracy-mcp --help
tracy-mcp analyze file.tracy
```

## Key Technical Details

### Tracy File Format (IMPORTANT)

**Tracy files use structured binary SECTIONS, NOT opcodes.** The opcode-based format is for Tracy's network protocol, not the file format.

File structure:
1. **Header**: Magic (`tracy0...`), version, multiplier, capture time, etc.
2. **Compressed data blocks**: Multi-stream ZSTD with interleaved blocks
3. **Sections** (in order):
   - Frame data
   - Strings (unique strings, ID mappings, thread names, external names)
   - Thread compression tables (local + external)
   - Source locations (static + expand array + payloads)
   - Source location zone statistics
   - Locks
   - Messages
   - Zone extras
   - Thread timelines (zones per thread)
   - Plots

### Multi-Stream ZSTD Compression

Tracy uses interleaved multi-stream compression:
- Blocks are distributed round-robin across N streams
- Each block: 4-byte size prefix + compressed data
- Must concatenate all blocks per stream, then decompress each stream
- Final data is interleaved byte-by-byte from all streams

### Source Location Two-Level Indirection

Zones store an `int16 srcloc_id`. Lookup requires two steps:
1. `srcloc_expand[id]` → `uint64 ptr`
2. `srcloc_by_ptr[ptr]` → `SourceLocation`

The expand array in the file **already includes** the reserved index 0.

### Packed Structs (no padding)

Tracy uses `#pragma pack(push, 1)`:
- **StringRef**: 9 bytes (uint64 str + uint8 flags)
- **SourceLocationBase**: 35 bytes (3×StringRef + 2×uint32)
- **ZoneExtra**: 12 bytes (4×Int24 for callstack, text, name, color)

### Zone Timeline Format

Zones use an interleaved format:
- First zone: srcloc + tstart + extra_idx + child_sz
- Subsequent: tend_prev + srcloc + tstart + extra_idx + child_sz
- Last zone's tend is read separately

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

## Verification

Use `tracy-csvexport` from TracyProfiler_jll to verify parser output:

```julia
using TracyProfiler_jll
run(`$(TracyProfiler_jll.tracy_csvexport()) /path/to/trace.tracy`)
```

Compare zone names, call counts, and total times against MCP `find_hotspots` output.

## Dependencies

- `ModelContextProtocol.jl` - MCP server framework
- `CodecZstd.jl` - ZSTD decompression
- `JSON3.jl` - JSON serialization
- `TranscodingStreams.jl` - Stream processing

## Reference

Tracy source code is available at `/home/sebastian/ai_sandbox/tracy`. Key files:
- `server/TracyWorker.cpp` - File loading logic
- `server/TracyVector.hpp` - `reserve_exact()` allocates and sets size
- `public/common/TracyQueue.hpp` - Network protocol opcodes (NOT file format)

## Known Limitations

1. **Memory events**: Not yet fully parsed
2. **GPU zones**: Not yet supported
3. **Callstack resolution**: Callstack frames not resolved to symbols

## Architecture Notes

- Global state (`CURRENT_TRACE`, `CURRENT_FILE`) holds the loaded trace for tool access
- Tools return JSON strings for MCP compatibility
- The `@main` function in TracyMCP.jl enables Pkg app support (Julia 1.12+)
