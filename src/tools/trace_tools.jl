# trace_tools.jl - MCP tools for Tracy trace analysis

using JSON3

# Global state for the currently loaded trace
const CURRENT_TRACE = Ref{Union{TracyTrace, Nothing}}(nothing)
const CURRENT_FILE = Ref{String}("")

"""
    tool_load_trace(file::String) -> String

Load a .tracy capture file for analysis.
Returns a summary of the loaded trace.
"""
function tool_load_trace(file::String)
    try
        # Expand path
        path = expanduser(file)
        if !isabspath(path)
            path = abspath(path)
        end

        if !isfile(path)
            return JSON3.write(Dict(
                "success" => false,
                "error" => "File not found: $path"
            ))
        end

        # Load the trace
        trace = read_tracy_file(path)
        CURRENT_TRACE[] = trace
        CURRENT_FILE[] = path

        # Return summary
        return JSON3.write(Dict(
            "success" => true,
            "file" => basename(path),
            "version" => string(trace.version),
            "program" => trace.capture.program_name,
            "threads" => length(trace.threads),
            "zones" => trace.total_zone_count,
            "source_locations" => length(trace.source_locations),
            "memory_events" => length(trace.memory_events),
            "messages" => length(trace.messages),
            "duration" => format_time(trace.capture_duration),
            "duration_ns" => trace.capture_duration
        ))
    catch e
        return JSON3.write(Dict(
            "success" => false,
            "error" => sprint(showerror, e)
        ))
    end
end

"""
    tool_get_trace_summary() -> String

Get a detailed summary of the currently loaded trace.
"""
function tool_get_trace_summary()
    trace = CURRENT_TRACE[]
    if trace === nothing
        return JSON3.write(Dict(
            "success" => false,
            "error" => "No trace loaded. Use load_trace first."
        ))
    end

    # Thread summary
    thread_info = []
    for (id, thread) in trace.threads
        push!(thread_info, Dict(
            "id" => id,
            "name" => thread.name,
            "zone_count" => length(thread.zones)
        ))
    end
    sort!(thread_info, by=x -> x["zone_count"], rev=true)

    # Frame info
    frame_info = Dict()
    for (name, frame) in trace.frames
        if !isempty(frame.times)
            frame_info[name] = Dict(
                "count" => length(frame.times),
                "avg_time" => length(frame.times) > 1 ?
                    format_time(sum(diff(frame.times)) ÷ (length(frame.times) - 1)) : "N/A"
            )
        end
    end

    return JSON3.write(Dict(
        "success" => true,
        "file" => basename(CURRENT_FILE[]),
        "version" => string(trace.version),
        "capture" => Dict(
            "program" => trace.capture.program_name,
            "host" => trace.capture.host_info,
            "os" => trace.capture.os_name,
            "resolution_ns" => trace.capture.resolution
        ),
        "duration" => format_time(trace.capture_duration),
        "duration_ns" => trace.capture_duration,
        "statistics" => Dict(
            "total_zones" => trace.total_zone_count,
            "source_locations" => length(trace.source_locations),
            "threads" => length(trace.threads),
            "memory_events" => length(trace.memory_events),
            "messages" => length(trace.messages)
        ),
        "threads" => thread_info[1:min(20, length(thread_info))],
        "frames" => frame_info
    ))
end

"""
    tool_find_hotspots(; limit::Int=20, by::String="total_time") -> String

Find the slowest zones by total or self time.
`by` can be "total_time", "call_count", "max_time", or "avg_time".
"""
function tool_find_hotspots(; limit::Int=20, by::String="total_time")
    trace = CURRENT_TRACE[]
    if trace === nothing
        return JSON3.write(Dict(
            "success" => false,
            "error" => "No trace loaded. Use load_trace first."
        ))
    end

    # Collect statistics
    stats = collect_zone_stats(trace)

    # Build result array with source location info
    results = []
    for (srcloc_id, stat) in stats
        loc = get(trace.source_locations, srcloc_id, nothing)

        entry = Dict(
            "srcloc_id" => srcloc_id,
            "name" => loc !== nothing ? loc.name : "<unknown>",
            "function" => loc !== nothing ? loc.function_name : "<unknown>",
            "file" => loc !== nothing ? loc.file : "<unknown>",
            "line" => loc !== nothing ? loc.line : 0,
            "call_count" => stat.call_count,
            "total_time" => format_time(stat.total_time),
            "total_time_ns" => stat.total_time,
            "min_time" => format_time(stat.min_time),
            "max_time" => format_time(stat.max_time),
            "avg_time" => format_time(stat.total_time ÷ stat.call_count),
            "avg_time_ns" => stat.total_time ÷ stat.call_count,
            "percent_of_total" => round(100.0 * stat.total_time / max(1, trace.capture_duration), digits=2)
        )
        push!(results, entry)
    end

    # Sort by requested metric
    if by == "total_time"
        sort!(results, by=x -> x["total_time_ns"], rev=true)
    elseif by == "call_count"
        sort!(results, by=x -> x["call_count"], rev=true)
    elseif by == "max_time"
        sort!(results, by=x -> parse(Int64, replace(x["max_time"], r"[^\d]" => "")), rev=true)
    elseif by == "avg_time"
        sort!(results, by=x -> x["avg_time_ns"], rev=true)
    end

    return JSON3.write(Dict(
        "success" => true,
        "sort_by" => by,
        "count" => min(limit, length(results)),
        "total_locations" => length(results),
        "hotspots" => results[1:min(limit, length(results))]
    ))
end

"""
    tool_analyze_function(function_name::String) -> String

Analyze all calls to a specific function.
Supports partial matching and regex patterns.
"""
function tool_analyze_function(function_name::String)
    trace = CURRENT_TRACE[]
    if trace === nothing
        return JSON3.write(Dict(
            "success" => false,
            "error" => "No trace loaded. Use load_trace first."
        ))
    end

    # Find matching source locations
    pattern = Regex(function_name, "i")  # Case insensitive
    matching_locs = Dict{Int16, SourceLocation}()

    for (id, loc) in trace.source_locations
        if occursin(pattern, loc.name) || occursin(pattern, loc.function_name)
            matching_locs[id] = loc
        end
    end

    if isempty(matching_locs)
        return JSON3.write(Dict(
            "success" => false,
            "error" => "No functions matching '$function_name' found",
            "suggestion" => "Try a broader pattern or check available source locations"
        ))
    end

    # Collect calls for matching locations
    stats = collect_zone_stats(trace)
    results = []

    for (id, loc) in matching_locs
        if haskey(stats, id)
            stat = stats[id]
            push!(results, Dict(
                "name" => loc.name,
                "function" => loc.function_name,
                "file" => loc.file,
                "line" => loc.line,
                "call_count" => stat.call_count,
                "total_time" => format_time(stat.total_time),
                "total_time_ns" => stat.total_time,
                "avg_time" => format_time(stat.total_time ÷ stat.call_count),
                "min_time" => format_time(stat.min_time),
                "max_time" => format_time(stat.max_time)
            ))
        end
    end

    sort!(results, by=x -> x["total_time_ns"], rev=true)

    # Find callers (zones that contain these zones)
    # This is an approximation based on timing

    return JSON3.write(Dict(
        "success" => true,
        "pattern" => function_name,
        "matches" => length(results),
        "functions" => results
    ))
end

"""
    tool_get_zone_tree(; thread_id::Union{UInt64,Nothing}=nothing, depth::Int=3) -> String

Get a hierarchical view of zones for a thread.
If thread_id is not specified, uses the thread with the most zones.
"""
function tool_get_zone_tree(; thread_id::Union{UInt64,Nothing}=nothing, depth::Int=3)
    trace = CURRENT_TRACE[]
    if trace === nothing
        return JSON3.write(Dict(
            "success" => false,
            "error" => "No trace loaded. Use load_trace first."
        ))
    end

    # Find thread
    thread = nothing
    if thread_id === nothing
        # Use thread with most zones
        max_zones = 0
        for (id, t) in trace.threads
            if length(t.zones) > max_zones
                max_zones = length(t.zones)
                thread = t
            end
        end
    else
        thread = get(trace.threads, thread_id, nothing)
    end

    if thread === nothing
        return JSON3.write(Dict(
            "success" => false,
            "error" => "Thread not found"
        ))
    end

    # Build hierarchical tree from flat zone list
    # Zones are sorted by start time, and a zone is a child of another
    # if it starts after and ends before the parent

    function zone_to_dict(zone::ZoneEvent, current_depth::Int)
        loc = get(trace.source_locations, zone.srcloc_id, nothing)
        result = Dict(
            "name" => loc !== nothing ? loc.name : "<unknown>",
            "file" => loc !== nothing ? "$(loc.file):$(loc.line)" : "<unknown>",
            "start_time" => zone.start_time,
            "duration" => format_time(get_zone_duration(zone)),
            "text" => zone.text
        )
        if current_depth < depth && !isempty(zone.children)
            result["children"] = [zone_to_dict(c, current_depth + 1) for c in zone.children]
        end
        return result
    end

    # Sort zones by start time
    sorted_zones = sort(thread.zones, by=z -> z.start_time)

    # Take first N zones for the tree view
    tree_zones = sorted_zones[1:min(50, length(sorted_zones))]

    tree = [zone_to_dict(z, 0) for z in tree_zones]

    return JSON3.write(Dict(
        "success" => true,
        "thread_id" => thread.id,
        "thread_name" => thread.name,
        "total_zones" => length(thread.zones),
        "showing" => length(tree),
        "tree" => tree
    ))
end

"""
    tool_search_zones(pattern::String; limit::Int=50) -> String

Search for zones matching a name pattern.
Recursively searches all zones including children.
"""
function tool_search_zones(pattern::String; limit::Int=50)
    trace = CURRENT_TRACE[]
    if trace === nothing
        return JSON3.write(Dict(
            "success" => false,
            "error" => "No trace loaded. Use load_trace first."
        ))
    end

    regex = Regex(pattern, "i")
    matches = []

    function search_zone(zone::ZoneEvent, thread_id::UInt64, thread_name::String)
        if length(matches) >= limit
            return
        end

        loc = get(trace.source_locations, zone.srcloc_id, nothing)
        if loc !== nothing
            # Match against zone name, function name, OR zone text
            if occursin(regex, loc.name) || occursin(regex, loc.function_name) || occursin(regex, zone.text)
                push!(matches, Dict(
                    "name" => loc.name,
                    "function" => loc.function_name,
                    "file" => loc.file,
                    "line" => loc.line,
                    "thread_id" => thread_id,
                    "thread_name" => thread_name,
                    "start_time" => zone.start_time,
                    "duration" => format_time(get_zone_duration(zone)),
                    "text" => zone.text
                ))
            end
        end

        # Recursively search children
        for child in zone.children
            search_zone(child, thread_id, thread_name)
            if length(matches) >= limit
                return
            end
        end
    end

    for (thread_id, thread) in trace.threads
        for zone in thread.zones
            search_zone(zone, thread_id, thread.name)
            if length(matches) >= limit
                break
            end
        end
        if length(matches) >= limit
            break
        end
    end

    return JSON3.write(Dict(
        "success" => true,
        "pattern" => pattern,
        "count" => length(matches),
        "limit" => limit,
        "zones" => matches
    ))
end

"""
    tool_get_memory_summary() -> String

Get memory allocation statistics from the trace.
"""
function tool_get_memory_summary()
    trace = CURRENT_TRACE[]
    if trace === nothing
        return JSON3.write(Dict(
            "success" => false,
            "error" => "No trace loaded. Use load_trace first."
        ))
    end

    if isempty(trace.memory_events)
        return JSON3.write(Dict(
            "success" => true,
            "message" => "No memory events in this trace",
            "total_allocations" => 0,
            "total_frees" => 0
        ))
    end

    # Track allocations
    allocations = Dict{UInt64, Int64}()  # ptr -> size
    total_allocated = 0
    peak_usage = 0
    current_usage = 0
    alloc_count = 0
    free_count = 0

    for event in trace.memory_events
        if event.size > 0
            # Allocation
            allocations[event.ptr] = event.size
            total_allocated += event.size
            current_usage += event.size
            peak_usage = max(peak_usage, current_usage)
            alloc_count += 1
        else
            # Free
            if haskey(allocations, event.ptr)
                current_usage -= allocations[event.ptr]
                delete!(allocations, event.ptr)
            end
            free_count += 1
        end
    end

    return JSON3.write(Dict(
        "success" => true,
        "total_allocations" => alloc_count,
        "total_frees" => free_count,
        "total_allocated" => format_bytes(total_allocated),
        "total_allocated_bytes" => total_allocated,
        "peak_usage" => format_bytes(peak_usage),
        "peak_usage_bytes" => peak_usage,
        "still_allocated" => length(allocations),
        "still_allocated_bytes" => current_usage,
        "still_allocated_formatted" => format_bytes(current_usage)
    ))
end

"""
    tool_get_thread_timeline(; thread_id::Union{UInt64,Nothing}=nothing,
                             time_start::Union{Int64,Nothing}=nothing,
                             time_end::Union{Int64,Nothing}=nothing,
                             limit::Int=100) -> String

Get a timeline of zone activity for a thread.
"""
function tool_get_thread_timeline(;
    thread_id::Union{UInt64,Nothing}=nothing,
    time_start::Union{Int64,Nothing}=nothing,
    time_end::Union{Int64,Nothing}=nothing,
    limit::Int=100
)
    trace = CURRENT_TRACE[]
    if trace === nothing
        return JSON3.write(Dict(
            "success" => false,
            "error" => "No trace loaded. Use load_trace first."
        ))
    end

    # Find thread
    thread = nothing
    if thread_id === nothing
        # Use thread with most zones
        max_zones = 0
        for (id, t) in trace.threads
            if length(t.zones) > max_zones
                max_zones = length(t.zones)
                thread = t
            end
        end
    else
        thread = get(trace.threads, thread_id, nothing)
    end

    if thread === nothing
        return JSON3.write(Dict(
            "success" => false,
            "error" => "Thread not found"
        ))
    end

    # Filter by time range
    zones = thread.zones
    if time_start !== nothing
        zones = filter(z -> z.end_time >= time_start, zones)
    end
    if time_end !== nothing
        zones = filter(z -> z.start_time <= time_end, zones)
    end

    # Sort by start time
    sorted = sort(zones, by=z -> z.start_time)

    # Limit results
    timeline = []
    for zone in sorted[1:min(limit, length(sorted))]
        loc = get(trace.source_locations, zone.srcloc_id, nothing)
        push!(timeline, Dict(
            "name" => loc !== nothing ? loc.name : "<unknown>",
            "file" => loc !== nothing ? loc.file : "<unknown>",
            "line" => loc !== nothing ? loc.line : 0,
            "start_time" => zone.start_time,
            "end_time" => zone.end_time,
            "duration" => format_time(get_zone_duration(zone)),
            "text" => zone.text
        ))
    end

    return JSON3.write(Dict(
        "success" => true,
        "thread_id" => thread.id,
        "thread_name" => thread.name,
        "total_zones_in_range" => length(zones),
        "showing" => length(timeline),
        "timeline" => timeline
    ))
end

"""
    tool_get_messages(; limit::Int=100) -> String

Get log messages from the trace.
"""
function tool_get_messages(; limit::Int=100)
    trace = CURRENT_TRACE[]
    if trace === nothing
        return JSON3.write(Dict(
            "success" => false,
            "error" => "No trace loaded. Use load_trace first."
        ))
    end

    if isempty(trace.messages)
        return JSON3.write(Dict(
            "success" => true,
            "message" => "No messages in this trace",
            "count" => 0
        ))
    end

    # Sort by time
    sorted = sort(trace.messages, by=m -> m.time)

    messages = []
    for msg in sorted[1:min(limit, length(sorted))]
        thread = get(trace.threads, msg.thread_id, nothing)
        push!(messages, Dict(
            "time" => msg.time,
            "thread_id" => msg.thread_id,
            "thread_name" => thread !== nothing ? thread.name : "<unknown>",
            "text" => msg.text,
            "color" => msg.color
        ))
    end

    return JSON3.write(Dict(
        "success" => true,
        "total" => length(trace.messages),
        "showing" => length(messages),
        "messages" => messages
    ))
end
