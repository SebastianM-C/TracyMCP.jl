# TracyReader.jl - Parser for Tracy .tracy capture files

include("types.jl")
include("decompression.jl")

# Tracy packet opcodes (subset needed for zone analysis)
# These are based on Tracy's ServerQuery enum
module Opcodes
    # Server query responses (string table entries)
    const StringData          = 0x01
    const ThreadName          = 0x02
    const SourceLocation      = 0x03
    const PlotName            = 0x04
    const FrameName           = 0x05

    # Zone events
    const ZoneBegin           = 0x10
    const ZoneBeginCallstack  = 0x11
    const ZoneEnd             = 0x12
    const ZoneValidation      = 0x13
    const ZoneColor           = 0x14
    const ZoneName            = 0x15
    const ZoneText            = 0x16
    const ZoneValue           = 0x17

    # Frame markers
    const FrameMarkMsg        = 0x20
    const FrameMarkMsgStart   = 0x21
    const FrameMarkMsgEnd     = 0x22

    # Memory events
    const MemAlloc            = 0x30
    const MemFree             = 0x31
    const MemAllocCallstack   = 0x32
    const MemFreeCallstack    = 0x33

    # Thread events
    const ThreadWakeup        = 0x40
    const ThreadContext       = 0x41

    # Messages
    const Message             = 0x50
    const MessageLiteral      = 0x51
    const MessageColor        = 0x52
    const MessageColorLiteral = 0x53

    # Source location (inline)
    const SourceLocationPayload = 0x60

    # Calibration/metadata
    const Calibration         = 0x70
    const Parameter           = 0x71
    const CpuTopology         = 0x72
    const HostInfo            = 0x73

    # Termination
    const Terminate           = 0xFF
end

"""
    ParserState

Mutable state for the parser, tracking reference times for delta decoding.
"""
mutable struct ParserState
    ref_time::Int64              # Reference time for delta decoding
    ref_thread::UInt64           # Current thread context
    string_refs::Dict{UInt64, String}  # Pending string references
    pending_zones::Dict{UInt64, Vector{ZoneEvent}}  # Per-thread zone stacks
end

ParserState() = ParserState(0, 0, Dict{UInt64, String}(), Dict{UInt64, Vector{ZoneEvent}}())

"""
    read_tracy_file(path::String) -> TracyTrace

Read and parse a .tracy capture file.
"""
function read_tracy_file(path::String)
    trace = TracyTrace()
    state = ParserState()

    open(path, "r") do io
        # Detect compression, version, and stream count
        compression, version, stream_count = detect_compression(io)
        trace.version = version

        @info "Parsing Tracy file" version compression stream_count

        # Create decompressing stream with multi-stream support
        stream = TracyInputStream(io, compression; stream_count=stream_count)

        # Read header/metadata first
        read_header!(stream, trace)

        # Parse packets until EOF
        parse_packets!(stream, trace, state)
    end

    # Post-process: compute statistics
    finalize_trace!(trace)

    return trace
end

"""
    read_header!(stream::TracyInputStream, trace::TracyTrace)

Read the file header and capture metadata.
"""
function read_header!(stream::TracyInputStream, trace::TracyTrace)
    # Read capture metadata
    # Format varies by version, but typically:
    # - multiplier (resolution): Float64
    # - init_time: Int64
    # - delay: Float64
    # - program name: String
    # etc.

    try
        trace.capture.resolution = read(stream, Float64)
        trace.capture.init_time = read(stream, Int64)
        trace.capture.delay = read(stream, Float64)
        trace.capture.epoch = read(stream, Int64)

        # Optional metadata strings
        trace.capture.program_name = read_string(stream)
        trace.capture.host_info = read_string(stream)
        trace.capture.os_name = read_string(stream)
    catch e
        if !(e isa EOFError)
            @warn "Error reading header, continuing with defaults" exception=e
        end
    end
end

"""
    parse_packets!(stream::TracyInputStream, trace::TracyTrace, state::ParserState)

Parse the packet stream until EOF or termination packet.
"""
function parse_packets!(stream::TracyInputStream, trace::TracyTrace, state::ParserState)
    packet_count = 0

    while !eof(stream)
        try
            opcode = read(stream, UInt8)

            if opcode == Opcodes.Terminate
                break
            end

            parse_packet!(stream, trace, state, opcode)
            packet_count += 1

            # Progress indicator for large files
            if packet_count % 100000 == 0
                @info "Parsed $packet_count packets..."
            end
        catch e
            if e isa EOFError
                break
            else
                @warn "Error parsing packet, skipping" exception=e
                # Try to continue
            end
        end
    end

    @info "Finished parsing" total_packets=packet_count
end

"""
    parse_packet!(stream, trace, state, opcode)

Parse a single packet based on its opcode.
"""
function parse_packet!(stream::TracyInputStream, trace::TracyTrace, state::ParserState, opcode::UInt8)

    if opcode == Opcodes.StringData
        parse_string_data!(stream, trace)

    elseif opcode == Opcodes.SourceLocation || opcode == Opcodes.SourceLocationPayload
        parse_source_location!(stream, trace)

    elseif opcode == Opcodes.ThreadName
        parse_thread_name!(stream, trace)

    elseif opcode == Opcodes.ThreadContext
        parse_thread_context!(stream, state)

    elseif opcode == Opcodes.ZoneBegin || opcode == Opcodes.ZoneBeginCallstack
        parse_zone_begin!(stream, trace, state, opcode == Opcodes.ZoneBeginCallstack)

    elseif opcode == Opcodes.ZoneEnd
        parse_zone_end!(stream, trace, state)

    elseif opcode == Opcodes.ZoneName
        parse_zone_name!(stream, trace, state)

    elseif opcode == Opcodes.ZoneText
        parse_zone_text!(stream, trace, state)

    elseif opcode == Opcodes.ZoneColor
        parse_zone_color!(stream, state)

    elseif opcode == Opcodes.MemAlloc || opcode == Opcodes.MemAllocCallstack
        parse_mem_alloc!(stream, trace, state, opcode == Opcodes.MemAllocCallstack)

    elseif opcode == Opcodes.MemFree || opcode == Opcodes.MemFreeCallstack
        parse_mem_free!(stream, trace, state, opcode == Opcodes.MemFreeCallstack)

    elseif opcode == Opcodes.Message || opcode == Opcodes.MessageLiteral
        parse_message!(stream, trace, state, opcode == Opcodes.MessageLiteral)

    elseif opcode == Opcodes.MessageColor || opcode == Opcodes.MessageColorLiteral
        parse_message_color!(stream, trace, state, opcode == Opcodes.MessageColorLiteral)

    elseif opcode == Opcodes.FrameMarkMsg
        parse_frame_mark!(stream, trace, state)

    elseif opcode == Opcodes.HostInfo
        parse_host_info!(stream, trace)

    elseif opcode == Opcodes.Calibration
        parse_calibration!(stream, trace)

    else
        # Unknown opcode - skip if we can determine size, otherwise log
        # @debug "Unknown opcode" opcode
    end
end

# ============== Packet Parsers ==============

function parse_string_data!(stream::TracyInputStream, trace::TracyTrace)
    # String table entry: ptr (8 bytes) + string
    ptr = read(stream, UInt64)
    str = read_string(stream)
    trace.string_table[ptr] = str
end

function parse_source_location!(stream::TracyInputStream, trace::TracyTrace)
    # Source location: id, name_ptr, function_ptr, file_ptr, line, color
    id = read(stream, Int16)
    name_ptr = read(stream, UInt64)
    function_ptr = read(stream, UInt64)
    file_ptr = read(stream, UInt64)
    line = read(stream, UInt32)
    color = read(stream, UInt32)

    # Resolve strings from table
    name = get(trace.string_table, name_ptr, "<unknown>")
    func = get(trace.string_table, function_ptr, "<unknown>")
    file = get(trace.string_table, file_ptr, "<unknown>")

    trace.source_locations[id] = SourceLocation(name, func, file, line, color)
end

function parse_thread_name!(stream::TracyInputStream, trace::TracyTrace)
    # Thread name: thread_id (8 bytes) + name string
    thread_id = read(stream, UInt64)
    name = read_string(stream)

    if !haskey(trace.threads, thread_id)
        trace.threads[thread_id] = ThreadData(thread_id, name)
    else
        trace.threads[thread_id].name = name
    end
end

function parse_thread_context!(stream::TracyInputStream, state::ParserState)
    # Thread context switch: thread_id
    state.ref_thread = read(stream, UInt64)
end

function parse_zone_begin!(stream::TracyInputStream, trace::TracyTrace, state::ParserState, has_callstack::Bool)
    # Zone begin: time_delta (leb128), srcloc (int16), [callstack_id if has_callstack]
    time_delta = read_leb128(stream)
    state.ref_time += time_delta

    srcloc = read(stream, Int16)

    if has_callstack
        _ = read(stream, UInt32)  # callstack_id - skip for now
    end

    # Create zone event
    zone = ZoneEvent()
    zone.start_time = state.ref_time
    zone.srcloc_id = srcloc

    # Ensure thread exists
    if !haskey(trace.threads, state.ref_thread)
        trace.threads[state.ref_thread] = ThreadData(state.ref_thread)
    end

    # Push to pending zone stack for this thread
    if !haskey(state.pending_zones, state.ref_thread)
        state.pending_zones[state.ref_thread] = ZoneEvent[]
    end
    push!(state.pending_zones[state.ref_thread], zone)
end

function parse_zone_end!(stream::TracyInputStream, trace::TracyTrace, state::ParserState)
    # Zone end: time_delta (leb128)
    time_delta = read_leb128(stream)
    state.ref_time += time_delta

    # Pop from zone stack
    if haskey(state.pending_zones, state.ref_thread) && !isempty(state.pending_zones[state.ref_thread])
        zone = pop!(state.pending_zones[state.ref_thread])
        zone.end_time = state.ref_time

        # Add to thread's zone list
        push!(trace.threads[state.ref_thread].zones, zone)
    end
end

function parse_zone_name!(stream::TracyInputStream, trace::TracyTrace, state::ParserState)
    # Zone name: string
    name = read_string(stream)

    # Attach to current zone
    if haskey(state.pending_zones, state.ref_thread) && !isempty(state.pending_zones[state.ref_thread])
        zone = state.pending_zones[state.ref_thread][end]
        # Update source location name if we have it
    end
end

function parse_zone_text!(stream::TracyInputStream, trace::TracyTrace, state::ParserState)
    # Zone text annotation
    text = read_string(stream)

    if haskey(state.pending_zones, state.ref_thread) && !isempty(state.pending_zones[state.ref_thread])
        zone = state.pending_zones[state.ref_thread][end]
        zone.text = text
    end
end

function parse_zone_color!(stream::TracyInputStream, state::ParserState)
    # Zone color: color (4 bytes)
    _ = read(stream, UInt32)  # Skip for now
end

function parse_mem_alloc!(stream::TracyInputStream, trace::TracyTrace, state::ParserState, has_callstack::Bool)
    # Memory allocation: time_delta, ptr, size, [callstack_id]
    time_delta = read_leb128(stream)
    state.ref_time += time_delta

    ptr = read(stream, UInt64)
    size = read_leb128(stream)

    callstack_id::UInt32 = 0
    if has_callstack
        callstack_id = read(stream, UInt32)
    end

    event = MemEvent(ptr, size, state.ref_time, state.ref_thread, 0, callstack_id)
    push!(trace.memory_events, event)
end

function parse_mem_free!(stream::TracyInputStream, trace::TracyTrace, state::ParserState, has_callstack::Bool)
    # Memory free: time_delta, ptr, [callstack_id]
    time_delta = read_leb128(stream)
    state.ref_time += time_delta

    ptr = read(stream, UInt64)

    callstack_id::UInt32 = 0
    if has_callstack
        callstack_id = read(stream, UInt32)
    end

    # Record as negative size to indicate free
    event = MemEvent(ptr, -1, state.ref_time, state.ref_thread, 0, callstack_id)
    push!(trace.memory_events, event)
end

function parse_message!(stream::TracyInputStream, trace::TracyTrace, state::ParserState, is_literal::Bool)
    # Message: time_delta, text
    time_delta = read_leb128(stream)
    state.ref_time += time_delta

    if is_literal
        ptr = read(stream, UInt64)
        text = get(trace.string_table, ptr, "<unknown>")
    else
        text = read_string(stream)
    end

    msg = MessageData(state.ref_time, state.ref_thread, text, 0)
    push!(trace.messages, msg)
end

function parse_message_color!(stream::TracyInputStream, trace::TracyTrace, state::ParserState, is_literal::Bool)
    # Colored message: time_delta, color, text
    time_delta = read_leb128(stream)
    state.ref_time += time_delta

    color = read(stream, UInt32)

    if is_literal
        ptr = read(stream, UInt64)
        text = get(trace.string_table, ptr, "<unknown>")
    else
        text = read_string(stream)
    end

    msg = MessageData(state.ref_time, state.ref_thread, text, color)
    push!(trace.messages, msg)
end

function parse_frame_mark!(stream::TracyInputStream, trace::TracyTrace, state::ParserState)
    # Frame mark: time_delta, name_ptr
    time_delta = read_leb128(stream)
    state.ref_time += time_delta

    name_ptr = read(stream, UInt64)
    name = get(trace.string_table, name_ptr, "main")

    if !haskey(trace.frames, name)
        trace.frames[name] = FrameData(name, Int64[], true)
    end
    push!(trace.frames[name].times, state.ref_time)
end

function parse_host_info!(stream::TracyInputStream, trace::TracyTrace)
    info = read_string(stream)
    trace.capture.host_info = info
end

function parse_calibration!(stream::TracyInputStream, trace::TracyTrace)
    # Calibration data
    mul = read(stream, Float64)
    trace.capture.resolution = mul
end

# ============== Finalization ==============

"""
    finalize_trace!(trace::TracyTrace)

Post-process the trace: compute statistics, sort events, etc.
"""
function finalize_trace!(trace::TracyTrace)
    # Count total zones
    trace.total_zone_count = sum(length(td.zones) for td in values(trace.threads); init=0)

    # Compute capture duration
    min_time = typemax(Int64)
    max_time = typemin(Int64)

    for thread in values(trace.threads)
        for zone in thread.zones
            min_time = min(min_time, zone.start_time)
            max_time = max(max_time, zone.end_time)
        end
    end

    if min_time != typemax(Int64)
        trace.capture_duration = max_time - min_time
    end

    @info "Trace finalized" zones=trace.total_zone_count threads=length(trace.threads) duration=format_time(trace.capture_duration)
end

# ============== Analysis Helpers ==============

"""
    get_zone_duration(zone::ZoneEvent) -> Int64

Get the duration of a zone in nanoseconds.
"""
function get_zone_duration(zone::ZoneEvent)
    return zone.end_time - zone.start_time
end

"""
    get_source_location(trace::TracyTrace, zone::ZoneEvent) -> Union{SourceLocation, Nothing}

Get the source location for a zone.
"""
function get_source_location(trace::TracyTrace, zone::ZoneEvent)
    return get(trace.source_locations, zone.srcloc_id, nothing)
end

"""
    collect_zone_stats(trace::TracyTrace) -> Dict{Int16, NamedTuple}

Collect statistics for each source location:
- call_count: number of times called
- total_time: sum of all durations
- self_time: time excluding children (approximation)
- min_time, max_time, avg_time
"""
function collect_zone_stats(trace::TracyTrace)
    stats = Dict{Int16, @NamedTuple{
        call_count::Int64,
        total_time::Int64,
        min_time::Int64,
        max_time::Int64
    }}()

    for thread in values(trace.threads)
        for zone in thread.zones
            duration = get_zone_duration(zone)
            if duration < 0
                continue  # Invalid zone
            end

            if haskey(stats, zone.srcloc_id)
                s = stats[zone.srcloc_id]
                stats[zone.srcloc_id] = (
                    call_count = s.call_count + 1,
                    total_time = s.total_time + duration,
                    min_time = min(s.min_time, duration),
                    max_time = max(s.max_time, duration)
                )
            else
                stats[zone.srcloc_id] = (
                    call_count = 1,
                    total_time = duration,
                    min_time = duration,
                    max_time = duration
                )
            end
        end
    end

    return stats
end
