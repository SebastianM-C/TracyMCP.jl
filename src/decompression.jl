# decompression.jl - LZ4/ZSTD block decompression for Tracy files

using CodecLz4
using CodecZstd
using TranscodingStreams

# Tracy compression constants
const TRACY_BLOCK_SIZE = 64 * 1024  # 64KB decompressed block size

# Magic bytes for detecting compression type
# Modern format: 'tr' + 0xFD + 'P' (then compression byte + stream count)
const MAGIC_TRACY = UInt8['t', 'r', 0xFD, 'P']  # Modern tracy header
const MAGIC_LZ4 = UInt8['t', 'l', 'Z', 0x04]   # Legacy LZ4 compressed
const MAGIC_ZSTD = UInt8['t', 'Z', 's', 't']   # Legacy ZSTD compressed

"""
    CompressionType

Enum for supported compression types in Tracy files.
"""
@enum CompressionType begin
    COMPRESSION_NONE
    COMPRESSION_LZ4
    COMPRESSION_ZSTD
end

"""
    MultiStreamDecompressor

Handles Tracy's multi-stream compression format where blocks are interleaved
across N streams. Each stream has its own Zstd/LZ4 frame, and the decompressed
output must be interleaved in 64KB chunks.
"""
mutable struct MultiStreamDecompressor <: IO
    io::IO
    stream_count::Int
    compression::CompressionType
    # Per-stream compressed data buffers
    stream_buffers::Vector{Vector{UInt8}}
    # Per-stream decompressed output
    decompressed::Vector{Vector{UInt8}}
    # Current position in interleaved output
    output_buffer::Vector{UInt8}
    output_pos::Int
    # Block reading state
    current_block::Int
    blocks_loaded::Bool
    eof_reached::Bool
end

function MultiStreamDecompressor(io::IO, compression::CompressionType, stream_count::Int)
    MultiStreamDecompressor(
        io,
        stream_count,
        compression,
        [UInt8[] for _ in 1:stream_count],
        [UInt8[] for _ in 1:stream_count],
        UInt8[],
        1,
        0,
        false,
        false
    )
end

"""Load all compressed blocks and distribute to streams."""
function load_all_blocks!(msd::MultiStreamDecompressor)
    if msd.blocks_loaded
        return
    end

    block_num = 0
    while !eof(msd.io)
        size_bytes = read(msd.io, 4)
        if length(size_bytes) < 4
            break
        end
        block_size = reinterpret(UInt32, size_bytes)[1]
        if block_size == 0
            break
        end

        compressed = read(msd.io, block_size)
        if length(compressed) < block_size
            break
        end

        stream_idx = (block_num % msd.stream_count) + 1
        append!(msd.stream_buffers[stream_idx], compressed)
        block_num += 1
    end

    msd.blocks_loaded = true
    @info "Loaded $block_num compressed blocks across $(msd.stream_count) streams"
end

"""Decompress all streams and interleave output."""
function decompress_and_interleave!(msd::MultiStreamDecompressor)
    if !msd.blocks_loaded
        load_all_blocks!(msd)
    end

    if !isempty(msd.output_buffer)
        return  # Already decompressed
    end

    # Decompress each stream
    for i in 1:msd.stream_count
        if msd.compression == COMPRESSION_ZSTD
            zstd_stream = ZstdDecompressorStream(IOBuffer(msd.stream_buffers[i]))
            while !eof(zstd_stream)
                try
                    chunk = read(zstd_stream, TRACY_BLOCK_SIZE)
                    append!(msd.decompressed[i], chunk)
                catch e
                    # Frame may be truncated at end - continue with what we have
                    break
                end
            end
        elseif msd.compression == COMPRESSION_LZ4
            lz4_stream = LZ4FrameDecompressorStream(IOBuffer(msd.stream_buffers[i]))
            while !eof(lz4_stream)
                try
                    chunk = read(lz4_stream, TRACY_BLOCK_SIZE)
                    append!(msd.decompressed[i], chunk)
                catch e
                    break
                end
            end
        else
            # No compression
            msd.decompressed[i] = msd.stream_buffers[i]
        end
        @info "Stream $i: $(length(msd.decompressed[i])) bytes decompressed"
    end

    # Interleave decompressed data in TRACY_BLOCK_SIZE chunks
    max_blocks = maximum(ceil(Int, length(d) / TRACY_BLOCK_SIZE) for d in msd.decompressed; init=0)
    for block_idx in 0:max_blocks-1
        for stream_idx in 1:msd.stream_count
            start = block_idx * TRACY_BLOCK_SIZE + 1
            stop = min((block_idx + 1) * TRACY_BLOCK_SIZE, length(msd.decompressed[stream_idx]))
            if start <= length(msd.decompressed[stream_idx])
                append!(msd.output_buffer, msd.decompressed[stream_idx][start:stop])
            end
        end
    end

    @info "Total interleaved output: $(length(msd.output_buffer)) bytes"
    msd.output_pos = 1
end

# IO interface for MultiStreamDecompressor
function Base.read(msd::MultiStreamDecompressor, ::Type{UInt8})
    decompress_and_interleave!(msd)
    if msd.output_pos > length(msd.output_buffer)
        msd.eof_reached = true
        throw(EOFError())
    end
    b = msd.output_buffer[msd.output_pos]
    msd.output_pos += 1
    return b
end

function Base.readbytes!(msd::MultiStreamDecompressor, buf::AbstractVector{UInt8}, n::Int)
    decompress_and_interleave!(msd)
    available = length(msd.output_buffer) - msd.output_pos + 1
    to_read = min(n, available)
    if to_read > 0
        copyto!(buf, 1, msd.output_buffer, msd.output_pos, to_read)
        msd.output_pos += to_read
    end
    if msd.output_pos > length(msd.output_buffer)
        msd.eof_reached = true
    end
    return to_read
end

Base.eof(msd::MultiStreamDecompressor) = msd.eof_reached || (msd.blocks_loaded && msd.output_pos > length(msd.output_buffer))
Base.isreadable(msd::MultiStreamDecompressor) = true
Base.iswritable(msd::MultiStreamDecompressor) = false
Base.isopen(msd::MultiStreamDecompressor) = isopen(msd.io)
Base.bytesavailable(msd::MultiStreamDecompressor) = max(0, length(msd.output_buffer) - msd.output_pos + 1)

"""
    TracyInputStream

Wrapper that reads block-compressed Tracy data using streaming decompression.

For multi-stream files (stream_count > 1), uses MultiStreamDecompressor to
handle the interleaved block format where each stream has its own compression
frame and decompressed output is interleaved in 64KB chunks.
"""
mutable struct TracyInputStream
    compression::CompressionType
    decompressor::IO             # Decompressor (single or multi-stream)
    buffer::Vector{UInt8}        # Read-ahead buffer for decompressed data
    position::Int                # Current position in buffer
    eof_reached::Bool

    function TracyInputStream(io::IO, compression::CompressionType; stream_count::Int=1)
        decompressor = if stream_count > 1
            # Multi-stream: use special handler
            MultiStreamDecompressor(io, compression, stream_count)
        elseif compression == COMPRESSION_ZSTD
            # Single stream Zstd - blocks form one continuous frame
            # But we still need to strip block size prefixes
            block_io = SingleStreamBlockIO(io)
            ZstdDecompressorStream(block_io)
        elseif compression == COMPRESSION_LZ4
            block_io = SingleStreamBlockIO(io)
            LZ4FrameDecompressorStream(block_io)
        else
            # No compression - read blocks directly
            SingleStreamBlockIO(io)
        end

        new(compression, decompressor, UInt8[], 1, false)
    end
end

"""
    SingleStreamBlockIO

IO wrapper for single-stream files that strips block size prefixes.
"""
mutable struct SingleStreamBlockIO <: IO
    io::IO
    current_block::Vector{UInt8}
    block_pos::Int
    eof_reached::Bool
end

SingleStreamBlockIO(io::IO) = SingleStreamBlockIO(io, UInt8[], 1, false)

function read_next_block!(bio::SingleStreamBlockIO)
    if eof(bio.io)
        bio.eof_reached = true
        return false
    end

    size_bytes = read(bio.io, 4)
    if length(size_bytes) < 4
        bio.eof_reached = true
        return false
    end

    block_size = reinterpret(UInt32, size_bytes)[1]
    if block_size == 0
        bio.eof_reached = true
        return false
    end

    bio.current_block = read(bio.io, block_size)
    bio.block_pos = 1
    return length(bio.current_block) == block_size
end

function Base.read(bio::SingleStreamBlockIO, ::Type{UInt8})
    while bio.block_pos > length(bio.current_block)
        if bio.eof_reached || !read_next_block!(bio)
            throw(EOFError())
        end
    end
    b = bio.current_block[bio.block_pos]
    bio.block_pos += 1
    return b
end

function Base.readbytes!(bio::SingleStreamBlockIO, buf::AbstractVector{UInt8}, n::Int)
    total_read = 0
    while total_read < n
        if bio.block_pos > length(bio.current_block)
            if bio.eof_reached || !read_next_block!(bio)
                break
            end
        end
        available = length(bio.current_block) - bio.block_pos + 1
        to_copy = min(available, n - total_read)
        copyto!(buf, total_read + 1, bio.current_block, bio.block_pos, to_copy)
        bio.block_pos += to_copy
        total_read += to_copy
    end
    return total_read
end

Base.eof(bio::SingleStreamBlockIO) = bio.eof_reached && bio.block_pos > length(bio.current_block)
Base.isreadable(bio::SingleStreamBlockIO) = true
Base.iswritable(bio::SingleStreamBlockIO) = false
Base.isopen(bio::SingleStreamBlockIO) = isopen(bio.io)
Base.bytesavailable(bio::SingleStreamBlockIO) = length(bio.current_block) - bio.block_pos + 1

"""
    detect_compression(io::IO) -> Tuple{CompressionType, VersionNumber, Int}

Detect the compression type and version from Tracy file header.
Returns (compression_type, tracy_version, stream_count).

Tracy file formats:
- Modern (TracyHeader): 'tr' + 0xFD + 'P' + compression_byte + stream_count
- Legacy LZ4: 'tlZ\\x04'
- Legacy ZSTD: 'tZst'
"""
function detect_compression(io::IO)
    # Read first 4 bytes for magic
    magic = read(io, 4)

    if magic == MAGIC_LZ4
        # Legacy LZ4 format - single stream, version unknown
        return COMPRESSION_LZ4, v"0.7.0", 1
    elseif magic == MAGIC_ZSTD
        # Legacy ZSTD format - single stream, version unknown
        return COMPRESSION_ZSTD, v"0.7.0", 1
    elseif magic == MAGIC_TRACY
        # Modern format: compression type (1 byte) + stream count (1 byte)
        compression_byte = read(io, UInt8)
        stream_count = Int(read(io, UInt8))

        # Compression: 0 = LZ4, 1 = Zstd
        compression = if compression_byte == 0x00
            COMPRESSION_LZ4
        elseif compression_byte == 0x01
            COMPRESSION_ZSTD
        else
            error("Unknown compression type: $compression_byte")
        end

        # Version is embedded in the compressed data, use placeholder
        # The actual protocol version is in the broadcast header inside compressed data
        return compression, v"0.11.0", max(1, stream_count)
    else
        error("Unknown Tracy file magic: 0x$(bytes2hex(magic)) ($(repr(String(copy(magic)))))")
    end
end

# IO interface for TracyInputStream
# With streaming decompression, we simply delegate to the decompressor

function Base.read(stream::TracyInputStream, ::Type{UInt8})
    if stream.eof_reached
        throw(EOFError())
    end
    try
        return read(stream.decompressor, UInt8)
    catch e
        if e isa EOFError
            stream.eof_reached = true
        end
        rethrow()
    end
end

function Base.read(stream::TracyInputStream, n::Int)
    if stream.eof_reached
        return UInt8[]
    end
    buf = Vector{UInt8}(undef, n)
    try
        actual = readbytes!(stream.decompressor, buf, n)
        if actual < n
            stream.eof_reached = true
            return buf[1:actual]
        end
        return buf
    catch e
        if e isa EOFError
            stream.eof_reached = true
            return UInt8[]
        end
        rethrow()
    end
end

function Base.read(stream::TracyInputStream, ::Type{T}) where T <: Number
    n = sizeof(T)
    bytes = read(stream, n)
    if length(bytes) < n
        throw(EOFError())
    end
    return reinterpret(T, bytes)[1]
end

function Base.eof(stream::TracyInputStream)
    stream.eof_reached || eof(stream.decompressor)
end

function Base.skip(stream::TracyInputStream, n::Integer)
    # Read and discard n bytes
    remaining = n
    buf = Vector{UInt8}(undef, min(remaining, TRACY_BLOCK_SIZE))
    while remaining > 0
        to_read = min(remaining, length(buf))
        actual = readbytes!(stream.decompressor, buf, to_read)
        remaining -= actual
        if actual < to_read
            stream.eof_reached = true
            return
        end
    end
end

"""
    read_string(stream::TracyInputStream) -> String

Read a length-prefixed string (2-byte length + bytes).
"""
function read_string(stream::TracyInputStream)
    len = read(stream, UInt16)
    if len == 0
        return ""
    end
    bytes = read(stream, Int(len))
    return String(bytes)
end

"""
    read_leb128(stream::TracyInputStream) -> Int64

Read a signed LEB128 encoded integer.
Tracy uses this for delta-encoded values.
"""
function read_leb128(stream::TracyInputStream)
    result::Int64 = 0
    shift = 0
    while true
        byte = read(stream, UInt8)
        result |= Int64(byte & 0x7F) << shift
        if (byte & 0x80) == 0
            # Sign extend if necessary
            if shift < 63 && (byte & 0x40) != 0
                result |= -(Int64(1) << (shift + 7))
            end
            break
        end
        shift += 7
    end
    return result
end

"""
    read_uleb128(stream::TracyInputStream) -> UInt64

Read an unsigned LEB128 encoded integer.
"""
function read_uleb128(stream::TracyInputStream)
    result::UInt64 = 0
    shift = 0
    while true
        byte = read(stream, UInt8)
        result |= UInt64(byte & 0x7F) << shift
        if (byte & 0x80) == 0
            break
        end
        shift += 7
    end
    return result
end
