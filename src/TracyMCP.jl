"""
    TracyMCP

MCP (Model Context Protocol) server for analyzing Tracy profiler captures.

This module provides tools for Claude to analyze .tracy capture files,
helping with Julia program performance analysis.

# Installation

Install as a Julia app:
```julia
using Pkg
Pkg.Apps.add(url="https://github.com/SebastianM-C/TracyMCP.jl")
```

# Usage

Configure in Claude Code's settings:
```json
{
  "mcpServers": {
    "tracy": {
      "command": "tracy-mcp"
    }
  }
}
```

Or run directly from Julia:
```julia
using TracyMCP
TracyMCP.run_server()
```

# CLI Commands

- `tracy-mcp` - Start MCP server (default)
- `tracy-mcp --help` - Show help
- `tracy-mcp analyze FILE` - Quick analysis of a .tracy file
"""
module TracyMCP

using ModelContextProtocol
import ModelContextProtocol: MCPTool, ServerConfig, Server, StdioTransport,
                             TextContent, ToolCapability, register!, start!
using JSON3

# Include sub-modules
include("TracyReader.jl")
include("tools/trace_tools.jl")

export run_server, read_tracy_file, TracyTrace

# ============== MCP Tool Definitions ==============

# Helper function to create a tool handler that parses JSON arguments
function make_handler(f::Function)
    return function(args::Dict)
        result = f(args)
        return [TextContent(result)]
    end
end

"""
    create_tools() -> Vector{MCPTool}

Create the MCP tool definitions for the server.
"""
function create_tools()
    tools = MCPTool[]

    # load_trace tool
    push!(tools, MCPTool(
        name = "load_trace",
        description = "Load a .tracy capture file for analysis. This must be called before using other analysis tools. Returns a summary of the loaded trace including thread count, zone count, and duration.",
        parameters = [],
        input_schema = Dict(
            "type" => "object",
            "properties" => Dict(
                "file" => Dict(
                    "type" => "string",
                    "description" => "Path to the .tracy capture file"
                )
            ),
            "required" => ["file"]
        ),
        handler = args -> begin
            file = get(args, "file", "")
            [TextContent(tool_load_trace(file))]
        end,
        return_type = Vector{TextContent}
    ))

    # get_trace_summary tool
    push!(tools, MCPTool(
        name = "get_trace_summary",
        description = "Get detailed summary of the currently loaded trace. Returns information about threads, zones, memory events, messages, and capture metadata.",
        parameters = [],
        input_schema = Dict(
            "type" => "object",
            "properties" => Dict()
        ),
        handler = args -> [TextContent(tool_get_trace_summary())],
        return_type = Vector{TextContent}
    ))

    # find_hotspots tool
    push!(tools, MCPTool(
        name = "find_hotspots",
        description = "Find the slowest zones in the trace. Returns a ranked list of functions/zones sorted by the specified metric. Use this to identify performance bottlenecks.",
        parameters = [],
        input_schema = Dict(
            "type" => "object",
            "properties" => Dict(
                "limit" => Dict(
                    "type" => "integer",
                    "description" => "Maximum number of results to return (default: 20)"
                ),
                "by" => Dict(
                    "type" => "string",
                    "description" => "Metric to sort by: total_time, call_count, max_time, or avg_time",
                    "enum" => ["total_time", "call_count", "max_time", "avg_time"]
                )
            )
        ),
        handler = args -> begin
            limit = get(args, "limit", 20)
            by = get(args, "by", "total_time")
            [TextContent(tool_find_hotspots(; limit=limit, by=by))]
        end,
        return_type = Vector{TextContent}
    ))

    # analyze_function tool
    push!(tools, MCPTool(
        name = "analyze_function",
        description = "Analyze all calls to a specific function. Supports partial matching and regex patterns. Returns call count, timing statistics, and source locations.",
        parameters = [],
        input_schema = Dict(
            "type" => "object",
            "properties" => Dict(
                "function_name" => Dict(
                    "type" => "string",
                    "description" => "Function name or regex pattern to search for"
                )
            ),
            "required" => ["function_name"]
        ),
        handler = args -> begin
            function_name = get(args, "function_name", "")
            [TextContent(tool_analyze_function(function_name))]
        end,
        return_type = Vector{TextContent}
    ))

    # get_zone_tree tool
    push!(tools, MCPTool(
        name = "get_zone_tree",
        description = "Get a hierarchical view of zones for a thread. Shows the call hierarchy with timing for each zone.",
        parameters = [],
        input_schema = Dict(
            "type" => "object",
            "properties" => Dict(
                "thread_id" => Dict(
                    "type" => "integer",
                    "description" => "Thread ID to analyze (uses busiest thread if not specified)"
                ),
                "depth" => Dict(
                    "type" => "integer",
                    "description" => "Maximum nesting depth to return (default: 3)"
                )
            )
        ),
        handler = args -> begin
            thread_id = get(args, "thread_id", nothing)
            depth = get(args, "depth", 3)
            tid = thread_id === nothing ? nothing : UInt64(thread_id)
            [TextContent(tool_get_zone_tree(; thread_id=tid, depth=depth))]
        end,
        return_type = Vector{TextContent}
    ))

    # search_zones tool
    push!(tools, MCPTool(
        name = "search_zones",
        description = "Search for zones matching a name pattern. Returns matching zones with their timing and context.",
        parameters = [],
        input_schema = Dict(
            "type" => "object",
            "properties" => Dict(
                "pattern" => Dict(
                    "type" => "string",
                    "description" => "Search pattern (supports regex)"
                ),
                "limit" => Dict(
                    "type" => "integer",
                    "description" => "Maximum number of results (default: 50)"
                )
            ),
            "required" => ["pattern"]
        ),
        handler = args -> begin
            pattern = get(args, "pattern", "")
            limit = get(args, "limit", 50)
            [TextContent(tool_search_zones(pattern; limit=limit))]
        end,
        return_type = Vector{TextContent}
    ))

    # get_memory_summary tool
    push!(tools, MCPTool(
        name = "get_memory_summary",
        description = "Get memory allocation statistics from the trace. Returns total allocations, peak usage, and potential leak information.",
        parameters = [],
        input_schema = Dict(
            "type" => "object",
            "properties" => Dict()
        ),
        handler = args -> [TextContent(tool_get_memory_summary())],
        return_type = Vector{TextContent}
    ))

    # get_thread_timeline tool
    push!(tools, MCPTool(
        name = "get_thread_timeline",
        description = "Get a timeline of zone activity for a thread. Returns zones in chronological order within the specified time range.",
        parameters = [],
        input_schema = Dict(
            "type" => "object",
            "properties" => Dict(
                "thread_id" => Dict(
                    "type" => "integer",
                    "description" => "Thread ID (uses busiest thread if not specified)"
                ),
                "time_start" => Dict(
                    "type" => "integer",
                    "description" => "Start time in nanoseconds (optional)"
                ),
                "time_end" => Dict(
                    "type" => "integer",
                    "description" => "End time in nanoseconds (optional)"
                ),
                "limit" => Dict(
                    "type" => "integer",
                    "description" => "Maximum zones to return (default: 100)"
                )
            )
        ),
        handler = args -> begin
            thread_id = get(args, "thread_id", nothing)
            time_start = get(args, "time_start", nothing)
            time_end = get(args, "time_end", nothing)
            limit = get(args, "limit", 100)
            tid = thread_id === nothing ? nothing : UInt64(thread_id)
            [TextContent(tool_get_thread_timeline(;
                thread_id=tid,
                time_start=time_start,
                time_end=time_end,
                limit=limit
            ))]
        end,
        return_type = Vector{TextContent}
    ))

    # get_messages tool
    push!(tools, MCPTool(
        name = "get_messages",
        description = "Get log messages from the trace. Returns messages in chronological order.",
        parameters = [],
        input_schema = Dict(
            "type" => "object",
            "properties" => Dict(
                "limit" => Dict(
                    "type" => "integer",
                    "description" => "Maximum messages to return (default: 100)"
                )
            )
        ),
        handler = args -> begin
            limit = get(args, "limit", 100)
            [TextContent(tool_get_messages(; limit=limit))]
        end,
        return_type = Vector{TextContent}
    ))

    return tools
end

"""
    handle_tool_call(name::String, arguments::Dict) -> String

Handle a tool call and return the result as JSON.
"""
function handle_tool_call(name::String, arguments::Dict)
    try
        if name == "load_trace"
            file = get(arguments, "file", "")
            return tool_load_trace(file)

        elseif name == "get_trace_summary"
            return tool_get_trace_summary()

        elseif name == "find_hotspots"
            limit = get(arguments, "limit", 20)
            by = get(arguments, "by", "total_time")
            return tool_find_hotspots(; limit=limit, by=by)

        elseif name == "analyze_function"
            function_name = get(arguments, "function_name", "")
            return tool_analyze_function(function_name)

        elseif name == "get_zone_tree"
            thread_id = get(arguments, "thread_id", nothing)
            depth = get(arguments, "depth", 3)
            tid = thread_id === nothing ? nothing : UInt64(thread_id)
            return tool_get_zone_tree(; thread_id=tid, depth=depth)

        elseif name == "search_zones"
            pattern = get(arguments, "pattern", "")
            limit = get(arguments, "limit", 50)
            return tool_search_zones(pattern; limit=limit)

        elseif name == "get_memory_summary"
            return tool_get_memory_summary()

        elseif name == "get_thread_timeline"
            thread_id = get(arguments, "thread_id", nothing)
            time_start = get(arguments, "time_start", nothing)
            time_end = get(arguments, "time_end", nothing)
            limit = get(arguments, "limit", 100)
            tid = thread_id === nothing ? nothing : UInt64(thread_id)
            return tool_get_thread_timeline(;
                thread_id=tid,
                time_start=time_start,
                time_end=time_end,
                limit=limit
            )

        elseif name == "get_messages"
            limit = get(arguments, "limit", 100)
            return tool_get_messages(; limit=limit)

        else
            return JSON3.write(Dict(
                "success" => false,
                "error" => "Unknown tool: $name"
            ))
        end
    catch e
        return JSON3.write(Dict(
            "success" => false,
            "error" => sprint(showerror, e),
            "backtrace" => sprint(Base.show_backtrace, catch_backtrace())
        ))
    end
end

"""
    run_server()

Start the MCP server using stdio transport.
This is the main entry point for running TracyMCP as an MCP server.
"""
function run_server()
    @info "Starting TracyMCP server..."

    # Create server configuration
    config = ServerConfig(
        name = "tracy-mcp",
        version = "0.1.0",
        description = "MCP server for analyzing Tracy profiler captures",
        capabilities = [ToolCapability()]
    )

    # Create server
    server = Server(config)

    # Create and register tools
    for tool in create_tools()
        register!(server, tool)
    end

    # Start server on stdio
    @info "TracyMCP server ready, waiting for connections..."
    start!(server; transport = StdioTransport())
end

# Convenience function for testing
"""
    load_and_analyze(file::String)

Load a trace file and print a summary.
Useful for quick testing outside of MCP context.
"""
function load_and_analyze(file::String)
    println("Loading trace: $file")
    result = tool_load_trace(file)
    data = JSON3.read(result)

    if data.success
        println("\n=== Trace Summary ===")
        println("Version: $(data.version)")
        println("Program: $(data.program)")
        println("Threads: $(data.threads)")
        println("Zones: $(data.zones)")
        println("Duration: $(data.duration)")

        println("\n=== Hotspots ===")
        hotspots = JSON3.read(tool_find_hotspots(; limit=10))
        if hotspots.success
            for (i, h) in enumerate(hotspots.hotspots)
                println("$i. $(h.name) - $(h.total_time) ($(h.call_count) calls)")
                println("   $(h.file):$(h.line)")
            end
        end
    else
        println("Error: $(data.error)")
    end
end

# ============== App Entry Point ==============

"""
    @main(ARGS)

Entry point for the Tracy MCP server when run as a Julia app.

Usage:
    tracy-mcp              # Start MCP server (default)
    tracy-mcp --help       # Show help
    tracy-mcp analyze FILE # Quick analysis of a .tracy file
"""
function (@main)(ARGS)
    if isempty(ARGS) || ARGS[1] == "serve"
        # Default: run MCP server
        run_server()
    elseif ARGS[1] == "--help" || ARGS[1] == "-h"
        println("""
Tracy MCP Server - Analyze Tracy profiler captures with Claude

Usage:
    tracy-mcp              Start the MCP server (stdio transport)
    tracy-mcp serve        Start the MCP server (explicit)
    tracy-mcp analyze FILE Quick analysis of a .tracy file
    tracy-mcp --help       Show this help message

MCP Server Setup:
    Add to your Claude Code settings:
    {
      "mcpServers": {
        "tracy": {
          "command": "tracy-mcp"
        }
      }
    }
""")
    elseif ARGS[1] == "analyze"
        if length(ARGS) < 2
            println("Error: Missing file argument")
            println("Usage: tracy-mcp analyze FILE")
            return 1
        end
        load_and_analyze(ARGS[2])
    else
        println("Unknown command: $(ARGS[1])")
        println("Run 'tracy-mcp --help' for usage information")
        return 1
    end
    return 0
end

end # module
