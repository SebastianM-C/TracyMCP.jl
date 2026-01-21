# types.jl - Data structures for Tracy trace data

"""
    SourceLocation

Represents a source code location in the trace.
Tracy stores these as static data with unique IDs.
"""
struct SourceLocation
    name::String           # Zone/function name
    function_name::String  # Full function signature
    file::String          # Source file path
    line::UInt32          # Line number
    color::UInt32         # Zone color (RGBA)
end

"""
    ZoneEvent

A CPU profiling zone event. In Tracy's binary format, these are
packed into bitfields for efficiency:
- Bits 0-15: source location ID (Int16)
- Bits 16-62: start time (47 bits)
- Bit 63: has child flag

Times are delta-encoded in the file and expanded during parsing.
"""
mutable struct ZoneEvent
    start_time::Int64      # Absolute start time in nanoseconds
    end_time::Int64        # Absolute end time in nanoseconds
    srcloc_id::Int16       # Source location ID
    text::String           # Zone text (optional annotation)
    children::Vector{ZoneEvent}  # Child zones (for hierarchical view)

    ZoneEvent() = new(0, 0, 0, "", ZoneEvent[])
    ZoneEvent(start::Int64, stop::Int64, srcloc::Int16) =
        new(start, stop, srcloc, "", ZoneEvent[])
    ZoneEvent(start::Int64, stop::Int64, srcloc::Int16, text::String, children::Vector{ZoneEvent}) =
        new(start, stop, srcloc, text, children)
end

"""Get the duration of a zone in nanoseconds."""
get_zone_duration(zone::ZoneEvent) = zone.end_time - zone.start_time

"""
    ThreadData

Per-thread zone timeline containing all zones executed on that thread.
"""
mutable struct ThreadData
    id::UInt64             # Thread ID
    name::String           # Thread name (if set)
    zones::Vector{ZoneEvent}  # Flat list of zone events

    ThreadData() = new(0, "", ZoneEvent[])
    ThreadData(id::UInt64, name::String="") = new(id, name, ZoneEvent[])
end

"""
    MemEvent

Memory allocation/deallocation event.
"""
struct MemEvent
    ptr::UInt64            # Pointer address
    size::Int64            # Size in bytes (negative for free)
    time::Int64            # Timestamp
    thread_id::UInt64      # Thread that made the allocation
    srcloc_id::Int16       # Source location where allocation occurred
    callstack_id::UInt32   # Callstack ID (if available)
end

"""
    MessageData

Log message recorded during the trace.
"""
struct MessageData
    time::Int64            # Timestamp
    thread_id::UInt64      # Thread that logged the message
    text::String           # Message text
    color::UInt32          # Message color (if colored message)
end

"""
    FrameData

Frame marker data for tracking frames/iterations.
"""
struct FrameData
    name::String           # Frame set name
    times::Vector{Int64}   # Frame boundary timestamps
    is_continuous::Bool    # Whether frames are continuous
end

"""
    TracyCapture

Metadata about the capture itself.
"""
mutable struct TracyCapture
    name::String           # Capture name
    program_name::String   # Program that was profiled
    host_info::String      # Host system info
    os_name::String        # Operating system
    resolution::Float64    # Timer resolution in nanoseconds
    delay::Float64         # Calibration delay
    init_time::Int64       # Initial timestamp
    epoch::Int64           # Unix epoch time at capture start
end

"""
    TracyTrace

Top-level container for all trace data.
"""
mutable struct TracyTrace
    version::VersionNumber # Tracy file format version
    capture::TracyCapture  # Capture metadata

    # String tables (pointer -> string mappings)
    string_table::Dict{UInt64, String}

    # Source locations (ID -> location)
    source_locations::Dict{Int16, SourceLocation}

    # Thread data
    threads::Dict{UInt64, ThreadData}

    # Memory events (sorted by time)
    memory_events::Vector{MemEvent}

    # Messages
    messages::Vector{MessageData}

    # Frame data
    frames::Dict{String, FrameData}

    # Computed statistics (populated after parsing)
    total_zone_count::Int64
    capture_duration::Int64  # Total capture duration in nanoseconds
end

function TracyTrace()
    TracyTrace(
        v"0.0.0",
        TracyCapture("", "", "", "", 1.0, 0.0, 0, 0),
        Dict{UInt64, String}(),
        Dict{Int16, SourceLocation}(),
        Dict{UInt64, ThreadData}(),
        MemEvent[],
        MessageData[],
        Dict{String, FrameData}(),
        0,
        0
    )
end

# Helper functions for time formatting

"""
    format_time(ns::Int64) -> String

Format nanoseconds as human-readable time.
"""
function format_time(ns::Int64)
    if ns < 1_000
        return "$(ns)ns"
    elseif ns < 1_000_000
        return "$(round(ns / 1_000, digits=2))μs"
    elseif ns < 1_000_000_000
        return "$(round(ns / 1_000_000, digits=2))ms"
    else
        return "$(round(ns / 1_000_000_000, digits=3))s"
    end
end

"""
    format_bytes(bytes::Int64) -> String

Format bytes as human-readable size.
"""
function format_bytes(bytes::Int64)
    if bytes < 1024
        return "$(bytes) B"
    elseif bytes < 1024^2
        return "$(round(bytes / 1024, digits=2)) KB"
    elseif bytes < 1024^3
        return "$(round(bytes / 1024^2, digits=2)) MB"
    else
        return "$(round(bytes / 1024^3, digits=2)) GB"
    end
end
