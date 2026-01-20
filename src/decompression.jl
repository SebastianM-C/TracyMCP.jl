# decompression.jl - LZ4/ZSTD block decompression for Tracy files

using CodecLz4
using CodecZstd
using TranscodingStreams

# Tracy compression constants
const TRACY_BLOCK_SIZE = 64 * 1024  # 64KB decompressed block size

# Magic bytes for detecting compression type
const MAGIC_TRACY = UInt8['t', 'r', 'c', 'y']  # Modern tracy header
const MAGIC_LZ4 = UInt8['t', 'l', 'Z', '4']    # Legacy LZ4 compressed
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
    TracyInputStream

Wrapper that reads block-compressed Tracy data.
Each block is prefixed with a 4-byte little-endian compressed size,
followed by that many bytes of compressed data that decompress to
up to TRACY_BLOCK_SIZE bytes.
"""
mutable struct TracyInputStream
    io::IO                       # Underlying IO stream
    compression::CompressionType # Compression type
    buffer::Vector{UInt8}        # Decompressed data buffer
    position::Int                # Current position in buffer
    eof_reached::Bool            # Whether we've hit end of data

    function TracyInputStream(io::IO, compression::CompressionType)
        new(io, compression, UInt8[], 1, false)
    end
end

"""
    detect_compression(io::IO) -> Tuple{CompressionType, VersionNumber}

Detect the compression type and version from Tracy file header.
Returns the compression type and tracy format version.
"""
function detect_compression(io::IO)
    # Read first 8 bytes for magic + version
    magic = read(io, 4)

    if magic == MAGIC_LZ4
        # Legacy LZ4 format - version is in compressed data
        return COMPRESSION_LZ4, v"0.7.0"  # Approximate
    elseif magic == MAGIC_ZSTD
        # Legacy ZSTD format
        return COMPRESSION_ZSTD, v"0.7.0"  # Approximate
    elseif magic == MAGIC_TRACY
        # Modern format - next 4 bytes are version
        version_raw = read(io, UInt32)
        major = (version_raw >> 16) & 0xFF
        minor = (version_raw >> 8) & 0xFF
        patch = version_raw & 0xFF
        version = VersionNumber(major, minor, patch)

        # Read signature byte to determine compression
        sig = read(io, UInt8)
        if sig == 0x00
            return COMPRESSION_NONE, version
        elseif sig == 0x01
            return COMPRESSION_LZ4, version
        elseif sig == 0x02
            return COMPRESSION_ZSTD, version
        else
            error("Unknown compression signature: $sig")
        end
    else
        error("Unknown Tracy file magic: $(String(copy(magic)))")
    end
end

"""
    read_block!(stream::TracyInputStream) -> Bool

Read and decompress the next block of data.
Returns true if a block was read, false if EOF.
"""
function read_block!(stream::TracyInputStream)
    if eof(stream.io)
        stream.eof_reached = true
        return false
    end

    # Read compressed block size (4 bytes little-endian)
    size_bytes = read(stream.io, 4)
    if length(size_bytes) < 4
        stream.eof_reached = true
        return false
    end

    compressed_size = reinterpret(UInt32, size_bytes)[1]

    if compressed_size == 0
        stream.eof_reached = true
        return false
    end

    # Read compressed data
    compressed = read(stream.io, compressed_size)
    if length(compressed) < compressed_size
        stream.eof_reached = true
        return false
    end

    # Decompress based on compression type
    if stream.compression == COMPRESSION_NONE
        stream.buffer = compressed
    elseif stream.compression == COMPRESSION_LZ4
        # LZ4 frame decompression
        stream.buffer = transcode(LZ4FrameDecompressor, compressed)
    elseif stream.compression == COMPRESSION_ZSTD
        # ZSTD decompression
        stream.buffer = transcode(ZstdDecompressor, compressed)
    end

    stream.position = 1
    return true
end

"""
    ensure_available!(stream::TracyInputStream, n::Int) -> Bool

Ensure at least n bytes are available in the buffer.
Returns false if not enough data is available (EOF).
"""
function ensure_available!(stream::TracyInputStream, n::Int)
    available = length(stream.buffer) - stream.position + 1

    if available >= n
        return true
    end

    if stream.eof_reached
        return false
    end

    # Save remaining data
    remaining = stream.buffer[stream.position:end]

    # Read next block
    if !read_block!(stream)
        # No more blocks - use what we have
        stream.buffer = remaining
        stream.position = 1
        return length(remaining) >= n
    end

    # Prepend remaining data to new buffer
    stream.buffer = vcat(remaining, stream.buffer)
    stream.position = 1

    return length(stream.buffer) >= n
end

# IO interface for TracyInputStream

function Base.read(stream::TracyInputStream, ::Type{UInt8})
    if !ensure_available!(stream, 1)
        throw(EOFError())
    end
    b = stream.buffer[stream.position]
    stream.position += 1
    return b
end

function Base.read(stream::TracyInputStream, n::Int)
    if !ensure_available!(stream, n)
        # Return what we have
        available = length(stream.buffer) - stream.position + 1
        if available > 0
            data = stream.buffer[stream.position:stream.position + available - 1]
            stream.position += available
            return data
        end
        return UInt8[]
    end
    data = stream.buffer[stream.position:stream.position + n - 1]
    stream.position += n
    return data
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
    if stream.position <= length(stream.buffer)
        return false
    end
    if stream.eof_reached
        return true
    end
    # Try to read another block
    if read_block!(stream)
        return false
    end
    return true
end

function Base.skip(stream::TracyInputStream, n::Integer)
    remaining = n
    while remaining > 0
        available = length(stream.buffer) - stream.position + 1
        if available >= remaining
            stream.position += remaining
            return
        end
        stream.position += available
        remaining -= available
        if !read_block!(stream)
            return  # EOF
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
