# frozen_string_literal: true

module Uprb
  # Hand-rolled length-prefixed binary format used to ship native extension
  # files (`.so` and companions) inside the packed output. Decoded at first
  # run by the bootstrap loader, which writes the files into the
  # content-addressed cache directory.
  #
  # Layout (all integers big-endian, unsigned):
  #
  #   uint32 version
  #   uint32 record_count
  #   record_count times:
  #     uint32 logical_name_size
  #     bytes  logical_name
  #     uint32 relative_path_size
  #     bytes  relative_path
  #     uint32 mode
  #     uint32 bytes_size
  #     bytes  bytes
  #
  # Stdlib only (no Marshal, no zlib) so the runtime decoder can be inlined
  # into the bootstrap loader and run under `--disable-gems`. `IO::Buffer` is
  # used to read/write fixed-width fields without intermediate allocations.
  module NativeSection
    VERSION = 1

    class << self
      # records: array of { logical_name:, relative_path:, mode:, bytes: }
      # Records are emitted in the given order; callers should sort by
      # relative_path for hash stability.
      def encode(records)
        Warning[:experimental] = false

        total = 8 # version + count
        records.each do |r|
          total += 4 + r.fetch(:logical_name).bytesize
          total += 4 + r.fetch(:relative_path).bytesize
          total += 4 + 4 + r.fetch(:bytes).bytesize
        end

        buf = IO::Buffer.new(total)
        offset = 0
        buf.set_value(:U32, offset, VERSION)
        offset += 4
        buf.set_value(:U32, offset, records.size)
        offset += 4
        records.each do |r|
          offset = write_string(buf, offset, r.fetch(:logical_name))
          offset = write_string(buf, offset, r.fetch(:relative_path))
          buf.set_value(:U32, offset, r.fetch(:mode) & 0xFFFFFFFF)
          offset += 4
          bytes = r.fetch(:bytes).b
          buf.set_value(:U32, offset, bytes.bytesize)
          offset += 4
          buf.set_string(bytes, offset)
          offset += bytes.bytesize
        end
        buf.get_string(0, total)
      end

      def decode(blob)
        Warning[:experimental] = false

        buf = IO::Buffer.for(blob)
        offset = 0
        version = buf.get_value(:U32, offset); offset += 4
        count = buf.get_value(:U32, offset); offset += 4
        raise Uprb::Error, "unsupported native section version: #{version}" unless version == VERSION

        Array.new(count) do
          ln_size = buf.get_value(:U32, offset); offset += 4
          ln = buf.get_string(offset, ln_size).force_encoding(Encoding::UTF_8); offset += ln_size
          rp_size = buf.get_value(:U32, offset); offset += 4
          rp = buf.get_string(offset, rp_size).force_encoding(Encoding::UTF_8); offset += rp_size
          mode = buf.get_value(:U32, offset); offset += 4
          bytes_size = buf.get_value(:U32, offset); offset += 4
          bytes = buf.get_string(offset, bytes_size); offset += bytes_size
          { logical_name: ln, relative_path: rp, mode: mode, bytes: bytes }
        end
      end

      private

      def write_string(buf, offset, str)
        bytes = str.b
        buf.set_value(:U32, offset, bytes.bytesize)
        offset += 4
        buf.set_string(bytes, offset)
        offset + bytes.bytesize
      end
    end
  end
end
