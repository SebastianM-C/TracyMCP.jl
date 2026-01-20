using Test
using TracyMCP
using JSON3

@testset "TracyMCP" begin

    @testset "Types" begin
        # Test type construction
        trace = TracyMCP.TracyTrace()
        @test trace.version == v"0.0.0"
        @test isempty(trace.threads)
        @test isempty(trace.source_locations)
        @test trace.total_zone_count == 0

        # Test ZoneEvent
        zone = TracyMCP.ZoneEvent(1000, 2000, Int16(1))
        @test zone.start_time == 1000
        @test zone.end_time == 2000
        @test TracyMCP.get_zone_duration(zone) == 1000

        # Test ThreadData
        thread = TracyMCP.ThreadData(UInt64(123), "main")
        @test thread.id == 123
        @test thread.name == "main"
        @test isempty(thread.zones)
    end

    @testset "Time Formatting" begin
        @test TracyMCP.format_time(500) == "500ns"
        @test TracyMCP.format_time(1500) == "1.5μs"
        @test TracyMCP.format_time(1_500_000) == "1.5ms"
        @test TracyMCP.format_time(1_500_000_000) == "1.5s"
    end

    @testset "Byte Formatting" begin
        @test TracyMCP.format_bytes(500) == "500 B"
        @test TracyMCP.format_bytes(1536) == "1.5 KB"
        @test TracyMCP.format_bytes(1_572_864) == "1.5 MB"
        @test TracyMCP.format_bytes(1_610_612_736) == "1.5 GB"
    end

    @testset "Tool Error Handling" begin
        # Test tools without loaded trace
        result = JSON3.read(TracyMCP.tool_get_trace_summary())
        @test result.success == false
        @test occursin("No trace loaded", result.error)

        result = JSON3.read(TracyMCP.tool_find_hotspots())
        @test result.success == false

        result = JSON3.read(TracyMCP.tool_analyze_function("test"))
        @test result.success == false

        # Test loading non-existent file
        result = JSON3.read(TracyMCP.tool_load_trace("/nonexistent/file.tracy"))
        @test result.success == false
        @test occursin("not found", result.error)
    end

    @testset "Compression Detection" begin
        # Test magic byte constants
        @test TracyMCP.MAGIC_TRACY == UInt8['t', 'r', 'c', 'y']
        @test TracyMCP.MAGIC_LZ4 == UInt8['t', 'l', 'Z', '4']
        @test TracyMCP.MAGIC_ZSTD == UInt8['t', 'Z', 's', 't']
    end

    @testset "LEB128 Encoding" begin
        # Create a mock stream with known LEB128 values
        # 0 -> 0x00
        # 1 -> 0x01
        # 127 -> 0x7F
        # 128 -> 0x80 0x01
        # 16384 -> 0x80 0x80 0x01

        # Test with simple buffer
        function test_leb128(bytes::Vector{UInt8})
            io = IOBuffer(bytes)
            stream = TracyMCP.TracyInputStream(io, TracyMCP.COMPRESSION_NONE)
            stream.buffer = bytes
            stream.position = 1
            return TracyMCP.read_uleb128(stream)
        end

        @test test_leb128([0x00]) == 0
        @test test_leb128([0x01]) == 1
        @test test_leb128([0x7F]) == 127
        @test test_leb128([0x80, 0x01]) == 128
        @test test_leb128([0x80, 0x80, 0x01]) == 16384
    end

    @testset "MCP Tools Creation" begin
        tools = TracyMCP.create_tools()
        @test length(tools) >= 8  # At least 8 tools defined

        tool_names = Set(t.name for t in tools)
        @test "load_trace" in tool_names
        @test "get_trace_summary" in tool_names
        @test "find_hotspots" in tool_names
        @test "analyze_function" in tool_names
        @test "search_zones" in tool_names
        @test "get_memory_summary" in tool_names
    end

    @testset "Handle Tool Call" begin
        # Test unknown tool
        result = JSON3.read(TracyMCP.handle_tool_call("unknown_tool", Dict()))
        @test result.success == false
        @test occursin("Unknown tool", result.error)

        # Test valid tool call (will fail because no trace loaded, but won't crash)
        result = JSON3.read(TracyMCP.handle_tool_call("get_trace_summary", Dict()))
        @test haskey(result, :success)
    end

end

# Integration tests (require actual .tracy files)
@testset "Integration Tests" begin
    @testset "Synthetic Trace" begin
        # Create a minimal synthetic trace in memory for testing
        trace = TracyMCP.TracyTrace()
        trace.version = v"0.9.0"
        trace.capture.program_name = "test_program"

        # Add a source location
        trace.source_locations[Int16(1)] = TracyMCP.SourceLocation(
            "test_zone",
            "test_function",
            "test.jl",
            UInt32(10),
            UInt32(0)
        )

        # Add a thread with zones
        thread = TracyMCP.ThreadData(UInt64(1), "main")
        push!(thread.zones, TracyMCP.ZoneEvent(0, 1_000_000, Int16(1)))  # 1ms
        push!(thread.zones, TracyMCP.ZoneEvent(1_000_000, 3_000_000, Int16(1)))  # 2ms
        trace.threads[UInt64(1)] = thread

        # Finalize
        TracyMCP.finalize_trace!(trace)

        @test trace.total_zone_count == 2
        @test trace.capture_duration == 3_000_000

        # Test zone stats collection
        stats = TracyMCP.collect_zone_stats(trace)
        @test haskey(stats, Int16(1))
        @test stats[Int16(1)].call_count == 2
        @test stats[Int16(1)].total_time == 3_000_000
    end
end

println("\nAll tests passed!")
