# Tracy MCP Server Implementation Plan

## Executive Summary

Build a Julia MCP server that enables Claude to interact with Tracy profiler data, providing AI-assisted performance analysis for Julia programs.

## Key Findings

### Tracy's Existing LLM Architecture

Tracy already has sophisticated LLM integration (`profiler/src/profiler/TracyLlm*.cpp`):

1. **OpenAI-Compatible API**: Connects to LLM servers via HTTP at configurable endpoint (default: `http://localhost:11434`)
2. **Built-in Tools** (8 total):
   - `source_file` - Retrieve source code around a line
   - `source_search` - Full-text search across source files
   - `user_manual` - Search Tracy documentation via embeddings
   - `search_wikipedia`, `get_wikipedia`, `get_dictionary` - Reference lookups
   - `search_web`, `get_webpage` - Web access

3. **Data Access**: Tools have access to `Worker` object which provides:
   - Zone timing data (CPU/GPU events)
   - Thread information
   - Memory allocations
   - Lock contention
   - Frame timing
   - Source file cache
   - Callstacks and symbols

### Julia Tracy Integration

Julia uses LibTracyClient C library for sending profiling data TO Tracy:
- 30+ timing subsystems (GC, INFERENCE, CODEGEN, etc.)
- 6 performance counters (HeapSize, JITSize, etc.)
- Fiber/task-aware profiling
- Connection via TCP port 8086

### Available Julia MCP Package

[ModelContextProtocol.jl](https://github.com/JuliaSMLM/ModelContextProtocol.jl) provides:
```julia
server = mcp_server(
    name = "tracy-profiler",
    tools = [my_tool1, my_tool2],
    resources = [my_resource]
)
start!(server)
```

## Architecture Options

### Option A: Tracy File Reader (Recommended for Phase 1)

```
┌─────────────────┐     ┌──────────────────────┐     ┌─────────────┐
│  Claude Code    │────▶│  Julia MCP Server    │────▶│ .tracy file │
│  (MCP Client)   │◀────│  (TracyMCP.jl)       │◀────│             │
└─────────────────┘     └──────────────────────┘     └─────────────┘
```

**Pros:**
- Independent of running Tracy GUI
- Can analyze saved profiling sessions
- Simpler architecture - just file parsing

**Cons:**
- Need to implement Tracy file format parsing (LZ4/ZSTD + binary)
- Can't control GUI or get live updates

**Tools to implement:**
- `load_trace(file)` - Load a .tracy capture file
- `get_zones(thread_id?, time_range?)` - Query zone events
- `get_hotspots(limit?)` - Find slowest zones
- `get_memory_allocations(time_range?)` - Memory analysis
- `get_thread_timeline(thread_id)` - Thread activity
- `get_lock_contention()` - Lock analysis
- `search_source(query)` - Search source files in trace
- `get_callstack(zone_id)` - Get callstack for a zone

### Option B: Bridge Tracy's LLM API to MCP

```
┌─────────────────┐     ┌──────────────────────┐     ┌─────────────┐
│  Tracy GUI      │────▶│  Julia MCP Server    │────▶│ Claude Code │
│  (LLM Client)   │◀────│  (OpenAI Compat.)    │◀────│(via MCP→API)│
└─────────────────┘     └──────────────────────┘     └─────────────┘
```

**Approach:** Create an OpenAI-compatible HTTP server in Julia that:
1. Receives requests from Tracy's LLM integration
2. Converts to MCP tool calls to Claude
3. Returns responses in OpenAI format

**Pros:**
- Uses Tracy's existing LLM tools
- Full access to Tracy's data via Worker
- Can leverage Tracy's UI

**Cons:**
- Complex protocol bridging
- Requires Tracy GUI to be running
- Less control over what tools are available

### Option C: Add MCP Tools to Tracy's Existing System

Modify Tracy C++ code to:
1. Add profiling-specific tools beyond source_file/source_search
2. Expose zone queries, performance analysis, etc.

**Pros:**
- Native Tracy integration
- Best performance

**Cons:**
- Requires C++ development in Tracy codebase
- Harder to iterate quickly

### Option D: Hybrid - Julia MCP Server + Tracy Protocol Client

```
┌─────────────────┐     ┌──────────────────────┐     ┌─────────────┐
│  Claude Code    │────▶│  Julia MCP Server    │────▶│Tracy Server │
│  (MCP Client)   │◀────│  (TracyMCP.jl)       │◀────│(live/file)  │
└─────────────────┘     └──────────────────────┘     └─────────────┘
                                   │
                                   ▼
                        ┌──────────────────────┐
                        │ TracyViewer.jl       │
                        │ (Protocol client)    │
                        └──────────────────────┘
```

Implement Tracy's viewer protocol in Julia to connect to running Tracy server.

**Pros:**
- Live profiling data
- Can work with both files and live sessions

**Cons:**
- Significant protocol implementation work

## Recommended Approach: Phased Implementation

### Phase 1: Static Analysis (Option A)

Build Julia MCP server that reads .tracy files:

1. **TracyFileReader.jl** - Parse Tracy capture files
   - Handle LZ4/ZSTD decompression
   - Parse binary event format

2. **TracyMCP.jl** - MCP server with analysis tools
   - Zone queries and filtering
   - Hotspot detection
   - Memory analysis
   - Source correlation

### Phase 2: OpenAI Bridge (Option B Enhancement)

Add OpenAI-compatible HTTP endpoint that:
- Receives Tracy's tool calls
- Routes to Claude via MCP
- Enables Claude to answer questions about loaded traces

### Phase 3: Live Integration (Option D)

Implement Tracy viewer protocol for live profiling analysis.

## Initial Tool Definitions

```julia
# Phase 1 tools for tracy_mcp/tools/

list_traces = MCPTool(
    name = "list_traces",
    description = "List available Tracy capture files",
    parameters = [
        ToolParameter(name="directory", type="string", required=false)
    ],
    handler = params -> ...
)

load_trace = MCPTool(
    name = "load_trace",
    description = "Load a Tracy capture file for analysis",
    parameters = [
        ToolParameter(name="file", type="string", required=true)
    ],
    handler = params -> ...
)

get_trace_summary = MCPTool(
    name = "get_trace_summary",
    description = "Get overview statistics of loaded trace",
    handler = params -> ...
)

find_hotspots = MCPTool(
    name = "find_hotspots",
    description = "Find the slowest zones in the trace",
    parameters = [
        ToolParameter(name="limit", type="integer", required=false),
        ToolParameter(name="thread_id", type="integer", required=false)
    ],
    handler = params -> ...
)

get_zone_details = MCPTool(
    name = "get_zone_details",
    description = "Get detailed info about a specific zone",
    parameters = [
        ToolParameter(name="zone_id", type="string", required=true)
    ],
    handler = params -> ...
)

analyze_memory = MCPTool(
    name = "analyze_memory",
    description = "Analyze memory allocation patterns",
    parameters = [
        ToolParameter(name="time_start", type="integer", required=false),
        ToolParameter(name="time_end", type="integer", required=false)
    ],
    handler = params -> ...
)

get_thread_timeline = MCPTool(
    name = "get_thread_timeline",
    description = "Get timeline of zones for a thread",
    parameters = [
        ToolParameter(name="thread_id", type="integer", required=true),
        ToolParameter(name="time_start", type="integer", required=false),
        ToolParameter(name="time_end", type="integer", required=false)
    ],
    handler = params -> ...
)
```

## Tracy File Format Notes

From `TracyFileRead.hpp`:
- Header: "tracy" or legacy LZ4/ZSTD headers
- Compression: LZ4 or ZSTD streams
- Multiple parallel decompression streams
- Binary format defined in `TracyEvent.hpp`

Key structures to parse:
- `ZoneEvent` - CPU profiling zones
- `GpuEvent` - GPU profiling zones
- `MemEvent` - Memory allocations
- `LockEvent` - Lock operations
- `MessageData` - Log messages
- `PlotData` - Metric plots

## Questions for Discussion

1. **Primary use case**: Analyzing saved traces vs. live profiling?

2. **Scope of Phase 1**: Should we focus only on Julia traces or support any Tracy capture?

3. **Integration depth**: Do you want to control Tracy GUI (navigate to zones, highlight) or just read data?

4. **Tool granularity**: Broad analysis tools vs. low-level data access?

## References

- [ModelContextProtocol.jl](https://github.com/JuliaSMLM/ModelContextProtocol.jl)
- Tracy source: `/home/sebastian/ai_sandbox/tracy`
- Tracy LLM: `profiler/src/profiler/TracyLlm*.cpp`
- File format: `server/TracyFileRead.hpp`, `server/TracyWorker.cpp`
- Protocol: `public/common/TracyProtocol.hpp`
