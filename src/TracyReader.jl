# TracyReader.jl - Parser for Tracy .tracy capture files
#
# Tracy file format documentation:
# - NOT an opcode stream (that's the network protocol)
# - Structured sections: header, strings, source locations, zones, messages, plots, etc.
# - Delta-encoded timestamps for compression
# - Hierarchical zone trees per thread
#
# Reference: tracy/server/TracyWorker.cpp

include("types.jl")
include("decompression.jl")

# File format constants
const FILE_HEADER_MAGIC = UInt8['t', 'r', 'a', 'c', 'y']
const FILE_HEADER_SIZE = 8  # magic (5) + version (3)

# Minimum supported file version
const MIN_FILE_VERSION = (0, 9, 0)

"""
    FileVersion(major, minor, patch) -> Int

Encode version as integer for comparison.
"""
FileVersion(major, minor, patch) = (major << 16) | (minor << 8) | patch

"""
    decode_version(v::Int) -> Tuple{Int, Int, Int}

Decode integer version to (major, minor, patch).
"""
function decode_version(v::Int)
    major = (v >> 16) & 0xFF
    minor = (v >> 8) & 0xFF
    patch = v & 0xFF
    return (major, minor, patch)
end

"""
    ParserState

Maintains state during file parsing.
"""
mutable struct ParserState
    ref_time::Int64           # Reference time for delta encoding
    ref_gpu_time::Int64       # Reference GPU time
    child_idx::Int32          # Zone children index counter
    version::Int              # File version as integer
    version_tuple::Tuple{Int,Int,Int}  # File version as tuple

    # Decompressed data buffer
    data::Vector{UInt8}
    position::Int

    # String lookup tables
    string_data::Dict{UInt64, String}      # ptr -> string
    string_map::Dict{UInt64, UInt64}       # id -> ptr
    thread_names::Dict{UInt64, String}     # thread_id -> name

    # Source location lookup (two-level indirection like Tracy)
    srcloc_by_ptr::Dict{UInt64, SourceLocation}  # ptr -> SourceLocation (static)
    srcloc_expand::Vector{UInt64}                 # int16 index -> ptr mapping
    srcloc_payload::Vector{SourceLocation}        # payload source locations (negative IDs)

    function ParserState()
        new(0, 0, 0, 0, (0,0,0), UInt8[], 1,
            Dict{UInt64, String}(),
            Dict{UInt64, UInt64}(),
            Dict{UInt64, String}(),
            Dict{UInt64, SourceLocation}(),
            UInt64[],  # File's expand array already includes reserved index 0
            SourceLocation[])
    end
end

# ============== Low-level read functions ==============

"""Read bytes from parser state buffer."""
function read_bytes!(state::ParserState, n::Int)
    if state.position + n - 1 > length(state.data)
        throw(EOFError())
    end
    result = state.data[state.position:state.position + n - 1]
    state.position += n
    return result
end

"""Read a value of type T from parser state."""
function read_value(state::ParserState, ::Type{T}) where T
    bytes = read_bytes!(state, sizeof(T))
    return reinterpret(T, bytes)[1]
end

"""Read Int64 with delta encoding."""
function read_time_delta!(state::ParserState)
    delta = read_value(state, Int64)
    state.ref_time += delta
    return state.ref_time
end

"""Read a length-prefixed string."""
function read_string!(state::ParserState)
    len = read_value(state, UInt64)
    if len == 0
        return ""
    end
    bytes = read_bytes!(state, Int(len))
    # Remove null terminator if present
    if !isempty(bytes) && bytes[end] == 0x00
        bytes = bytes[1:end-1]
    end
    return String(bytes)
end

"""Read a short string (UInt16 length prefix)."""
function read_short_string!(state::ParserState)
    len = read_value(state, UInt16)
    if len == 0
        return ""
    end
    bytes = read_bytes!(state, Int(len))
    return String(bytes)
end

"""Skip n bytes."""
function skip!(state::ParserState, n::Int)
    state.position += n
end

"""Check if at end of data."""
function eof(state::ParserState)
    return state.position > length(state.data)
end

"""Remaining bytes."""
function remaining(state::ParserState)
    return length(state.data) - state.position + 1
end

# ============== File Header Parsing ==============

"""
    read_file_header!(io::IO) -> Tuple{version, compression_type, stream_count}

Read and validate Tracy file header.
"""
function read_file_header!(io::IO)
    # Check for modern compressed format first
    magic = read(io, 4)

    if magic == MAGIC_TRACY
        # Modern format: compression type + stream count after magic
        comp_byte = read(io, UInt8)
        stream_count = read(io, UInt8)

        compression = comp_byte == 0x00 ? COMPRESSION_LZ4 : COMPRESSION_ZSTD

        # Version comes after decompression in modern format
        return (nothing, compression, Int(stream_count))

    elseif magic == MAGIC_LZ4
        return (nothing, COMPRESSION_LZ4, 1)

    elseif magic == MAGIC_ZSTD
        return (nothing, COMPRESSION_ZSTD, 1)

    else
        # Try legacy uncompressed format with tracy magic
        seek(io, 0)
        full_magic = read(io, 5)
        if full_magic == FILE_HEADER_MAGIC
            # Uncompressed legacy format
            ver_bytes = read(io, 3)
            version = FileVersion(Int(ver_bytes[1]), Int(ver_bytes[2]), Int(ver_bytes[3]))
            return (version, COMPRESSION_NONE, 1)
        else
            error("Invalid Tracy file: unrecognized magic bytes")
        end
    end
end

"""
    read_trace_header!(state::ParserState, trace::TracyTrace)

Read trace metadata from decompressed data.
"""
function read_trace_header!(state::ParserState, trace::TracyTrace)
    # First 8 bytes are magic + version in decompressed stream
    magic = read_bytes!(state, 5)
    if magic != FILE_HEADER_MAGIC
        error("Invalid decompressed data: expected tracy magic, got $(String(copy(magic)))")
    end

    ver_bytes = read_bytes!(state, 3)
    state.version = FileVersion(Int(ver_bytes[1]), Int(ver_bytes[2]), Int(ver_bytes[3]))
    state.version_tuple = (Int(ver_bytes[1]), Int(ver_bytes[2]), Int(ver_bytes[3]))

    trace.version = VersionNumber(state.version_tuple...)

    @info "Tracy file version" version=trace.version

    # Check minimum version
    if state.version < FileVersion(MIN_FILE_VERSION...)
        error("Unsupported Tracy file version: $(trace.version), minimum is $(MIN_FILE_VERSION)")
    end

    # Read metadata fields (matches Tracy's Read8 call)
    # Order: resolution, timerMul, lastTime, frameOffset, pid, samplingPeriod, cpuArch, cpuId
    trace.capture.resolution = read_value(state, Int64)
    timer_mul = read_value(state, Float64)
    last_time = read_value(state, Int64)
    frame_offset = read_value(state, UInt64)
    pid = read_value(state, UInt64)
    sampling_period = read_value(state, Int64)
    cpu_arch = read_value(state, UInt8)
    cpu_id = read_value(state, UInt32)

    # CPU manufacturer (12 bytes, null-terminated)
    cpu_mfr_bytes = read_bytes!(state, 12)
    null_idx = findfirst(==(0x00), cpu_mfr_bytes)
    cpu_mfr = null_idx === nothing ? String(cpu_mfr_bytes) : String(cpu_mfr_bytes[1:null_idx-1])

    # On-demand flag (v0.9.2+)
    if state.version >= FileVersion(0, 9, 2)
        on_demand = read_value(state, UInt8)
    end

    # Capture name (length-prefixed string)
    trace.capture.program_name = read_string!(state)

    # Capture program name + capture time
    program_name = read_string!(state)
    capture_time = read_value(state, UInt64)

    # Executable time (always present in modern versions)
    exec_time = read_value(state, UInt64)

    # Host info
    trace.capture.host_info = read_string!(state)

    # Note: OS name is embedded IN the hostInfo string, not a separate field

    @info "Trace metadata" program=trace.capture.program_name resolution=trace.capture.resolution
end

# ============== CPU Topology ==============

function read_cpu_topology!(state::ParserState, trace::TracyTrace)
    num_packages = read_value(state, UInt64)

    for _ in 1:num_packages
        package_id = read_value(state, UInt32)

        if state.version >= FileVersion(0, 11, 2)
            # New format with dies
            num_dies = read_value(state, UInt64)
            for _ in 1:num_dies
                die_id = read_value(state, UInt32)
                num_cores = read_value(state, UInt64)
                for _ in 1:num_cores
                    core_id = read_value(state, UInt32)
                    num_threads = read_value(state, UInt64)
                    for _ in 1:num_threads
                        thread_id = read_value(state, UInt32)
                    end
                end
            end
        else
            # Old format without dies
            num_cores = read_value(state, UInt64)
            for _ in 1:num_cores
                core_id = read_value(state, UInt32)
                num_threads = read_value(state, UInt64)
                for _ in 1:num_threads
                    thread_id = read_value(state, UInt32)
                end
            end
        end
    end
end

# ============== Frame Data ==============

function read_frame_data!(state::ParserState, trace::TracyTrace)
    num_frames = read_value(state, UInt64)

    for _ in 1:num_frames
        name_ref = read_value(state, UInt64)
        continuous = read_value(state, UInt8) != 0
        frame_count = read_value(state, UInt64)

        frame = FrameData(
            resolve_string(state, name_ref),
            Int64[],
            continuous
        )

        ref_time = Int64(0)
        for _ in 1:frame_count
            delta = read_value(state, Int64)
            ref_time += delta
            push!(frame.times, ref_time)

            if !continuous
                end_delta = read_value(state, Int64)
                ref_time += end_delta
            end

            # Frame image index
            _ = read_value(state, Int32)
        end

        name = resolve_string(state, name_ref)
        if !isempty(name)
            trace.frames[name] = frame
        end
    end
end

# ============== String Data ==============

function read_strings!(state::ParserState, trace::TracyTrace)
    # Unique strings
    num_strings = read_value(state, UInt64)
    for _ in 1:num_strings
        ptr = read_value(state, UInt64)
        str = read_string!(state)
        state.string_data[ptr] = str
        trace.string_table[ptr] = str
    end

    # String ID mappings
    num_mappings = read_value(state, UInt64)
    for _ in 1:num_mappings
        id = read_value(state, UInt64)
        ptr = read_value(state, UInt64)
        state.string_map[id] = ptr
    end

    # Thread names
    num_thread_names = read_value(state, UInt64)
    for _ in 1:num_thread_names
        thread_id = read_value(state, UInt64)
        ptr = read_value(state, UInt64)
        if haskey(state.string_data, ptr)
            state.thread_names[thread_id] = state.string_data[ptr]
        end
    end

    # External names (pairs)
    num_external = read_value(state, UInt64)
    for _ in 1:num_external
        _ = read_value(state, UInt64)  # id
        _ = read_value(state, UInt64)  # ptr1
        _ = read_value(state, UInt64)  # ptr2
    end

    @info "Loaded strings" unique=num_strings mappings=num_mappings thread_names=num_thread_names
end

# ============== Thread Compression Data ==============

"""
    read_thread_compress!(state::ParserState) -> Int

Read thread compression data (lookup table for compressed thread IDs).
Returns the number of entries read.
"""
function read_thread_compress!(state::ParserState)
    count = read_value(state, UInt64)
    # Each entry is a uint64 (original thread ID)
    for _ in 1:count
        _ = read_value(state, UInt64)
    end
    return Int(count)
end

"""Resolve a string reference to actual string."""
function resolve_string(state::ParserState, ref::UInt64)
    # Direct lookup
    if haskey(state.string_data, ref)
        return state.string_data[ref]
    end
    # Via mapping
    if haskey(state.string_map, ref)
        ptr = state.string_map[ref]
        if haskey(state.string_data, ptr)
            return state.string_data[ptr]
        end
    end
    return ""
end

# ============== Source Locations ==============

"""
    read_string_ref!(state::ParserState) -> UInt64

Read a Tracy StringRef (9 bytes: uint64 str + uint8 flags).
Returns just the string pointer value.
"""
function read_string_ref!(state::ParserState)
    str_value = read_value(state, UInt64)
    _flags = read_value(state, UInt8)  # isidx:1, active:1 - we don't need these
    return str_value
end

"""
    read_source_location_base!(state::ParserState) -> Tuple{UInt64, UInt64, UInt64, UInt32, UInt32}

Read SourceLocationBase struct (35 bytes packed).
Returns (name_ref, func_ref, file_ref, line, color).
"""
function read_source_location_base!(state::ParserState)
    name_ref = read_string_ref!(state)
    func_ref = read_string_ref!(state)
    file_ref = read_string_ref!(state)
    line = read_value(state, UInt32)
    color = read_value(state, UInt32)
    return (name_ref, func_ref, file_ref, line, color)
end

function read_source_locations!(state::ParserState, trace::TracyTrace)
    # Static source locations: stored by ptr key
    num_static = read_value(state, UInt64)
    for _ in 1:num_static
        ptr = read_value(state, UInt64)

        name_ref, func_ref, file_ref, line, color = read_source_location_base!(state)

        srcloc = SourceLocation(
            resolve_string(state, name_ref),
            resolve_string(state, func_ref),
            resolve_string(state, file_ref),
            line,
            color
        )

        # Store by ptr key (like Tracy's m_data.sourceLocation)
        state.srcloc_by_ptr[ptr] = srcloc
    end

    # Source location expand: maps int16 index -> uint64 ptr
    # This is the crucial mapping that zones use!
    num_expand = read_value(state, UInt64)
    for _ in 1:num_expand
        ptr = read_value(state, UInt64)
        push!(state.srcloc_expand, ptr)
    end

    # Dynamic source location payloads (for negative IDs)
    num_payloads = read_value(state, UInt64)
    for _ in 1:num_payloads
        name_ref, func_ref, file_ref, line, color = read_source_location_base!(state)

        srcloc = SourceLocation(
            resolve_string(state, name_ref),
            resolve_string(state, func_ref),
            resolve_string(state, file_ref),
            line,
            color
        )

        push!(state.srcloc_payload, srcloc)
    end

    # Now populate trace.source_locations using the expand mapping
    # For positive IDs: expand[id] -> ptr -> srcloc_by_ptr[ptr]
    for (idx, ptr) in enumerate(state.srcloc_expand)
        if idx == 1
            continue  # Index 0 is reserved/invalid
        end
        if haskey(state.srcloc_by_ptr, ptr)
            # idx is 1-based in Julia, but Tracy uses it directly as int16
            # Since we start with [0] in expand, idx-1 gives the Tracy index
            trace.source_locations[Int16(idx - 1)] = state.srcloc_by_ptr[ptr]
        end
    end

    # For negative IDs: payload array (1-indexed in Julia, so -1 -> payload[1])
    for (i, srcloc) in enumerate(state.srcloc_payload)
        trace.source_locations[Int16(-i)] = srcloc
    end

    @info "Loaded source locations" static=num_static expand=num_expand payloads=num_payloads
end

"""
    get_source_location(state::ParserState, id::Int16) -> Union{SourceLocation, Nothing}

Get a source location by its int16 ID (as used by zones).
- Positive IDs: lookup via expand array -> ptr -> srcloc_by_ptr
- Negative IDs: direct lookup in payload array
"""
function get_source_location(state::ParserState, id::Int16)
    if id < 0
        # Negative IDs: payload array (1-indexed, so -1 -> index 1)
        idx = -Int(id)
        if idx <= length(state.srcloc_payload)
            return state.srcloc_payload[idx]
        end
    elseif id > 0
        # Positive IDs: expand[id+1] -> ptr -> srcloc_by_ptr
        # +1 because expand[1] is the reserved 0 entry
        expand_idx = Int(id) + 1
        if expand_idx <= length(state.srcloc_expand)
            ptr = state.srcloc_expand[expand_idx]
            if haskey(state.srcloc_by_ptr, ptr)
                return state.srcloc_by_ptr[ptr]
            end
        end
    end
    return nothing
end

# ============== Source Location Statistics ==============

"""
    read_source_location_zones!(state::ParserState)

Read source location zone statistics (count per source location).
These are precomputed stats, not the actual zones themselves.
"""
function read_source_location_zones!(state::ParserState)
    start_pos = state.position

    # CPU source location zones
    num_entries = read_value(state, UInt64)
    @info "Source location zone stats - CPU" count=num_entries position=state.position
    for _ in 1:num_entries
        _id = read_value(state, Int16)
        _count = read_value(state, UInt64)
    end

    # GPU source location zones
    num_gpu_entries = read_value(state, UInt64)
    @info "Source location zone stats - GPU" count=num_gpu_entries position=state.position
    for _ in 1:num_gpu_entries
        _id = read_value(state, Int16)
        _count = read_value(state, UInt64)
    end

    bytes_read = state.position - start_pos
    @info "Source location zone stats done" bytes_read=bytes_read
end

# ============== Zone Extra Data ==============

"""
    ZoneExtraData

Parsed zone extra data (12 bytes in file):
- callstack: Int24 (3 bytes)
- text: StringIdx (3 bytes) -> index into string table
- name: StringIdx (3 bytes) -> index into string table
- color: Int24 (3 bytes)
"""
struct ZoneExtraData
    callstack::UInt32   # 3-byte Int24 stored as UInt32
    text_idx::UInt32    # 3-byte StringIdx stored as UInt32
    name_idx::UInt32    # 3-byte StringIdx stored as UInt32
    color::UInt32       # 3-byte Int24 stored as UInt32
end

"""Read a 3-byte Int24/StringIdx as UInt32."""
function read_int24!(state::ParserState)
    b1 = read_value(state, UInt8)
    b2 = read_value(state, UInt8)
    b3 = read_value(state, UInt8)
    return UInt32(b1) | (UInt32(b2) << 8) | (UInt32(b3) << 16)
end

function read_zone_extra!(state::ParserState)::Vector{ZoneExtraData}
    num_extra = read_value(state, UInt64)
    @info "Zone extra count" count=num_extra

    if num_extra == 0
        return ZoneExtraData[]
    end

    # ZoneExtra is 12 bytes: callstack(3) + text(3) + name(3) + color(3)
    extras = Vector{ZoneExtraData}(undef, num_extra)
    for i in 1:num_extra
        callstack = read_int24!(state)
        text_idx = read_int24!(state)
        name_idx = read_int24!(state)
        color = read_int24!(state)
        extras[i] = ZoneExtraData(callstack, text_idx, name_idx, color)
    end

    return extras
end

# ============== Zone Timeline ==============

"""
    read_zone_timeline!(state, trace, thread, count, extras) -> Int64

Read zone events for a thread using Tracy's interleaved format.
Returns final reference time.

Tracy format:
- First zone: srcloc(int16) + tstart(int64) + extra(uint32) + childSz(uint32)
- Middle zones: After children, read tend(int64) + srcloc(int16) + tstart(int64) + extra(uint32) + childSz(uint32)
- Last zone: After children, read tend(int64) only
"""
function read_zone_timeline!(state::ParserState, trace::TracyTrace,
                            thread::ThreadData, count::Int,
                            extras::Vector{ZoneExtraData})
    if count == 0
        return state.ref_time
    end

    # Read first zone's start data
    srcloc = read_value(state, Int16)
    tstart = read_value(state, Int64)
    extra_idx = read_value(state, UInt32)
    child_sz = read_value(state, UInt32)

    for i in 1:count
        # Apply start time
        state.ref_time += tstart
        start_time = state.ref_time

        # Create zone
        text = get_zone_text(extras, extra_idx, state)
        zone = ZoneEvent(start_time, start_time, srcloc, text, ZoneEvent[])

        # Read children recursively
        if child_sz > 0
            read_zone_children_recursive!(state, trace, zone, Int(child_sz), extras)
        end

        # Read end time (and next zone's start if not last)
        if i < count
            # Read: tend + next zone's start data
            tend = read_value(state, Int64)
            srcloc = read_value(state, Int16)
            tstart = read_value(state, Int64)
            extra_idx = read_value(state, UInt32)
            child_sz = read_value(state, UInt32)
        else
            # Last zone: just read tend
            tend = read_value(state, Int64)
        end

        # Apply end time
        state.ref_time += tend
        zone.end_time = state.ref_time

        push!(thread.zones, zone)
    end

    return state.ref_time
end

"""Get zone text from extras."""
function get_zone_text(extras::Vector{ZoneExtraData}, extra_idx::UInt32, state::ParserState)
    if extra_idx > 0 && extra_idx <= length(extras)
        text_idx = extras[extra_idx].text_idx
        if text_idx > 0
            return resolve_string(state, UInt64(text_idx - 1))
        end
    end
    return ""
end

"""Read zone children recursively."""
function read_zone_children_recursive!(state::ParserState, trace::TracyTrace,
                                       parent::ZoneEvent, count::Int,
                                       extras::Vector{ZoneExtraData})
    if count == 0
        return
    end

    # Read first child's start data
    srcloc = read_value(state, Int16)
    tstart = read_value(state, Int64)
    extra_idx = read_value(state, UInt32)
    child_sz = read_value(state, UInt32)

    for i in 1:count
        # Apply start time
        state.ref_time += tstart
        start_time = state.ref_time

        # Create child zone
        text = get_zone_text(extras, extra_idx, state)
        child = ZoneEvent(start_time, start_time, srcloc, text, ZoneEvent[])

        # Read grandchildren recursively
        if child_sz > 0
            read_zone_children_recursive!(state, trace, child, Int(child_sz), extras)
        end

        # Read end time (and next sibling's start if not last)
        if i < count
            tend = read_value(state, Int64)
            srcloc = read_value(state, Int16)
            tstart = read_value(state, Int64)
            extra_idx = read_value(state, UInt32)
            child_sz = read_value(state, UInt32)
        else
            tend = read_value(state, Int64)
        end

        # Apply end time
        state.ref_time += tend
        child.end_time = state.ref_time

        push!(parent.children, child)
    end
end

# ============== Thread Data ==============

function read_threads!(state::ParserState, trace::TracyTrace,
                      extras::Vector{ZoneExtraData})
    # Total zone count (for progress)
    total_zones = read_value(state, UInt64)

    # Number of zone children vectors
    num_children_vectors = read_value(state, UInt64)

    # Number of threads
    num_threads = read_value(state, UInt64)

    @info "Reading threads" count=num_threads total_zones=total_zones

    for i in 1:num_threads
        thread_id = read_value(state, UInt64)
        zone_count = read_value(state, UInt64)
        kernel_sample_count = read_value(state, UInt64)  # kernelSampleCnt - separate from samples below
        is_fiber = read_value(state, UInt8) != 0

        # Group hint (v0.11.1+)
        if state.version >= FileVersion(0, 11, 1)
            group_hint = read_value(state, Int32)
        end

        @debug "Thread header" id=thread_id zones=zone_count kernel_samples=kernel_sample_count fiber=is_fiber

        # Get thread name
        thread_name = get(state.thread_names, thread_id, "Thread $thread_id")
        thread = ThreadData(thread_id, thread_name)

        # Read timeline size (always read, even if 0)
        timeline_size = read_value(state, UInt32)
        if timeline_size > 0
            state.ref_time = 0
            read_zone_timeline!(state, trace, thread, Int(timeline_size), extras)
        end

        trace.threads[thread_id] = thread

        # Read messages for this thread
        num_messages = read_value(state, UInt64)
        # Skip message pointers for now (they reference the messages section)
        skip!(state, Int(num_messages * 8))

        # Read context switch samples (ssz count, then data)
        ctx_samples_count = read_value(state, UInt64)
        if ctx_samples_count > 0
            # Each sample is 11 bytes: time(8) + callstack(3)
            skip!(state, Int(ctx_samples_count * 11))
        end

        # Read regular samples (ssz count, then data)
        samples_count = read_value(state, UInt64)
        if samples_count > 0
            # Each sample is 11 bytes: time(8) + callstack(3)
            skip!(state, Int(samples_count * 11))
        end
    end

    @info "Threads parsed" count=length(trace.threads)
end

# ============== Messages ==============

function read_messages!(state::ParserState, trace::TracyTrace)
    num_messages = read_value(state, UInt64)

    ref_time = Int64(0)
    for _ in 1:num_messages
        # Message pointer (for lookups)
        _ = read_value(state, UInt64)

        # Time (delta encoded)
        delta = read_value(state, Int64)
        ref_time += delta

        # String reference
        str_ref = read_value(state, UInt64)

        # Color
        color = read_value(state, UInt32)

        # Callstack (skip)
        _ = read_value(state, UInt32)

        # Message source and severity (v0.13.2+)
        if state.version >= FileVersion(0, 13, 2)
            _ = read_value(state, UInt8)  # source
            _ = read_value(state, UInt8)  # severity
        end

        text = resolve_string(state, str_ref)
        msg = MessageData(ref_time, UInt64(0), text, color)
        push!(trace.messages, msg)
    end

    @info "Loaded messages" count=num_messages
end

# ============== Plots (Counters) ==============

function read_plots!(state::ParserState, trace::TracyTrace)
    num_plots = read_value(state, UInt64)

    for _ in 1:num_plots
        plot_type = read_value(state, UInt8)
        format = read_value(state, UInt8)
        show_steps = read_value(state, UInt8)
        fill = read_value(state, UInt8)
        color = read_value(state, UInt32)
        name_ref = read_value(state, UInt64)
        min_val = read_value(state, Float64)
        max_val = read_value(state, Float64)
        sum_val = read_value(state, Float64)

        num_points = read_value(state, UInt64)

        name = resolve_string(state, name_ref)

        # Skip memory plots (they're handled separately)
        if plot_type == 1  # PlotType::Memory
            # Skip the data points
            ref_time = Int64(0)
            for _ in 1:num_points
                delta = read_value(state, Int64)
                ref_time += delta
                _ = read_value(state, Float64)
            end
            continue
        end

        # Read plot data points into a FrameData structure (reusing for simplicity)
        times = Int64[]
        ref_time = Int64(0)
        for _ in 1:num_points
            delta = read_value(state, Int64)
            ref_time += delta
            value = read_value(state, Float64)
            push!(times, ref_time)
            # TODO: Store values properly
        end

        if !isempty(name)
            trace.frames[name] = FrameData(name, times, true)
        end
    end

    @info "Loaded plots" count=num_plots
end

# ============== Main Entry Point ==============

"""
    read_tracy_file(filepath::String) -> TracyTrace

Read and parse a Tracy capture file.
"""
function read_tracy_file(filepath::String)
    if !isfile(filepath)
        error("File not found: $filepath")
    end

    trace = TracyTrace()
    state = ParserState()

    open(filepath, "r") do io
        # Read file header to determine compression
        version, compression, stream_count = read_file_header!(io)

        @info "Parsing Tracy file" compression=compression stream_count=stream_count

        # Decompress the data
        seek(io, 0)  # Reset to start

        if compression == COMPRESSION_NONE
            # Uncompressed - read directly
            state.data = read(io)
        else
            # Compressed - use decompressor
            state.data = decompress_tracy_file(io, compression, stream_count)
        end

        @info "Decompressed data" size=length(state.data)
    end

    # Parse decompressed data
    try
        read_trace_header!(state, trace)
        read_cpu_topology!(state, trace)

        # CrashEvent struct: uint64 thread, int64 time, uint64 message, uint32 callstack = 28 bytes
        crash_thread = read_value(state, UInt64)
        crash_time = read_value(state, Int64)
        crash_message = read_value(state, UInt64)
        crash_callstack = read_value(state, UInt32)
        @debug "Crash event" thread=crash_thread time=crash_time

        read_frame_data!(state, trace)
        read_strings!(state, trace)

        # Thread compression data (lookup tables for compressed thread IDs)
        local_thread_count = read_thread_compress!(state)
        external_thread_count = read_thread_compress!(state)
        @debug "Thread compress" local_count=local_thread_count external_count=external_thread_count

        read_source_locations!(state, trace)
        read_source_location_zones!(state)

        @info "Before locks" position=state.position remaining=remaining(state)
        # Skip lock data for now
        num_locks = read_value(state, UInt64)
        @info "Lock count" count=num_locks hex=string(num_locks, base=16)
        if num_locks > 0 && num_locks < 1000000  # Sanity check
            @info "Skipping locks" count=num_locks
            # Would need to parse lock events here
        elseif num_locks >= 1000000
            @warn "Suspicious lock count - possible misalignment" count=num_locks
        end

        @info "Before messages" position=state.position remaining=remaining(state)
        read_messages!(state, trace)

        # Read zone extra data
        extras = read_zone_extra!(state)

        # Read threads and zones
        read_threads!(state, trace, extras)

        # Read plots
        read_plots!(state, trace)

    catch e
        @warn "Error during parsing" exception=(e, catch_backtrace()) position=state.position remaining=remaining(state)
        # Continue with partial data
    end

    finalize_trace!(trace)
    return trace
end

"""
    decompress_tracy_file(io::IO, compression, stream_count) -> Vector{UInt8}

Decompress Tracy file data.
"""
function decompress_tracy_file(io::IO, compression::CompressionType, stream_count::Int)
    # Skip the initial header (already read)
    seek(io, 0)
    magic = read(io, 4)

    if magic == MAGIC_TRACY
        # Modern format
        _ = read(io, UInt8)  # compression byte
        _ = read(io, UInt8)  # stream count

        if stream_count > 1
            return decompress_multi_stream(io, compression, stream_count)
        else
            return decompress_single_stream(io, compression)
        end
    elseif magic == MAGIC_LZ4 || magic == MAGIC_ZSTD
        # Legacy single-stream
        return decompress_single_stream(io, compression)
    else
        error("Unknown compression format")
    end
end

"""Decompress single-stream Tracy data."""
function decompress_single_stream(io::IO, compression::CompressionType)
    output = UInt8[]

    while !Base.eof(io)
        # Read block size
        block_size_bytes = read(io, 4)
        if length(block_size_bytes) < 4
            break
        end
        block_size = reinterpret(UInt32, block_size_bytes)[1]

        if block_size == 0
            break
        end

        # Read compressed block
        compressed = read(io, block_size)
        if length(compressed) < block_size
            break
        end

        # Decompress
        if compression == COMPRESSION_LZ4
            decompressed = transcode(LZ4FrameDecompressor, compressed)
        else
            decompressed = transcode(ZstdDecompressor, compressed)
        end

        append!(output, decompressed)
    end

    return output
end

"""Decompress multi-stream Tracy data."""
function decompress_multi_stream(io::IO, compression::CompressionType, stream_count::Int)
    # Read all blocks
    blocks = Vector{Vector{UInt8}}()

    while !Base.eof(io)
        block_size_bytes = read(io, 4)
        if length(block_size_bytes) < 4
            break
        end
        block_size = reinterpret(UInt32, block_size_bytes)[1]

        if block_size == 0
            break
        end

        compressed = read(io, block_size)
        if length(compressed) < block_size
            break
        end

        push!(blocks, compressed)
    end

    @info "Loaded compressed blocks" count=length(blocks) streams=stream_count

    # Distribute blocks to streams (round-robin)
    streams = [Vector{UInt8}[] for _ in 1:stream_count]
    for (i, block) in enumerate(blocks)
        stream_idx = ((i - 1) % stream_count) + 1
        push!(streams[stream_idx], block)
    end

    # Concatenate blocks per stream (blocks within a stream form one continuous frame)
    # Then decompress each concatenated stream using streaming decompressor
    # (handles potentially truncated final frames gracefully)
    decompressed_streams = Vector{Vector{UInt8}}(undef, stream_count)
    for i in 1:stream_count
        # Concatenate all blocks for this stream
        concatenated = UInt8[]
        for block in streams[i]
            append!(concatenated, block)
        end

        # Decompress using streaming approach to handle truncated frames
        io_buf = IOBuffer(concatenated)
        decompressor = if compression == COMPRESSION_LZ4
            LZ4FrameDecompressorStream(io_buf)
        else
            ZstdDecompressorStream(io_buf)
        end

        decompressed = UInt8[]
        chunk_size = 64 * 1024
        try
            while !Base.eof(decompressor)
                chunk = Base.read(decompressor, chunk_size)
                append!(decompressed, chunk)
            end
        catch e
            # Handle truncated frame - keep what we decompressed
            @warn "Stream $i decompression ended early (truncated frame)" exception=e bytes_decompressed=length(decompressed)
        end

        decompressed_streams[i] = decompressed
        @info "Stream $i: $(length(concatenated)) bytes compressed -> $(length(decompressed)) bytes decompressed"
    end

    # Interleave streams (64KB chunks)
    output = UInt8[]
    chunk_size = 64 * 1024
    positions = ones(Int, stream_count)

    while true
        any_data = false
        for i in 1:stream_count
            stream = decompressed_streams[i]
            pos = positions[i]
            if pos <= length(stream)
                end_pos = min(pos + chunk_size - 1, length(stream))
                append!(output, stream[pos:end_pos])
                positions[i] = end_pos + 1
                any_data = true
            end
        end
        if !any_data
            break
        end
    end

    @info "Total interleaved output" size=length(output)
    return output
end

# ============== Finalization ==============

"""
    finalize_trace!(trace::TracyTrace)

Compute derived statistics for the trace.
"""
function finalize_trace!(trace::TracyTrace)
    # Count total zones
    total_zones = 0
    min_time = typemax(Int64)
    max_time = typemin(Int64)

    for thread in values(trace.threads)
        total_zones += count_zones(thread.zones)
        for zone in thread.zones
            min_time = min(min_time, zone.start_time)
            max_time = max(max_time, zone.end_time)
        end
    end

    trace.total_zone_count = total_zones

    if min_time != typemax(Int64) && max_time != typemin(Int64)
        trace.capture_duration = max_time - min_time
    else
        trace.capture_duration = 0
    end

    @info "Trace finalized" zones=total_zones threads=length(trace.threads) duration=format_time(trace.capture_duration)
end

"""Count zones including children."""
function count_zones(zones::Vector{ZoneEvent})
    count = length(zones)
    for zone in zones
        count += count_zones(zone.children)
    end
    return count
end

# format_time and format_bytes are defined in types.jl

"""
    collect_zone_stats(trace::TracyTrace) -> Dict{Int16, NamedTuple}

Collect statistics for each source location.
"""
function collect_zone_stats(trace::TracyTrace)
    stats = Dict{Int16, NamedTuple{(:call_count, :total_time, :min_time, :max_time), Tuple{Int, Int64, Int64, Int64}}}()

    function process_zones(zones::Vector{ZoneEvent})
        for zone in zones
            duration = zone.end_time - zone.start_time
            srcloc = zone.srcloc_id

            if haskey(stats, srcloc)
                s = stats[srcloc]
                stats[srcloc] = (
                    call_count = s.call_count + 1,
                    total_time = s.total_time + duration,
                    min_time = min(s.min_time, duration),
                    max_time = max(s.max_time, duration)
                )
            else
                stats[srcloc] = (
                    call_count = 1,
                    total_time = duration,
                    min_time = duration,
                    max_time = duration
                )
            end

            process_zones(zone.children)
        end
    end

    for thread in values(trace.threads)
        process_zones(thread.zones)
    end

    return stats
end
