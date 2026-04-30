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
  # into the bootstrap loader and run under `--disable-gems`.
  module NativeSection
    VERSION = 1

    class << self
      # records: array of { logical_name:, relative_path:, mode:, bytes: }
      # The records are emitted in the given order; callers should sort by
      # relative_path for hash stability.
      def encode(records)
        io = String.new(encoding: Encoding::BINARY)
        io << [VERSION, records.size].pack("NN")
        records.each do |r|
          write_string(io, r.fetch(:logical_name))
          write_string(io, r.fetch(:relative_path))
          io << [r.fetch(:mode) & 0xFFFFFFFF, r.fetch(:bytes).bytesize].pack("NN")
          io << r.fetch(:bytes).b
        end
        io
      end

      def decode(blob)
        b = blob.b
        pos = 0
        version, count = b[pos, 8].unpack("NN")
        pos += 8
        raise Uprb::Error, "unsupported native section version: #{version}" unless version == VERSION

        records = Array.new(count) do
          ln_size = b[pos, 4].unpack1("N"); pos += 4
          ln = b[pos, ln_size].force_encoding(Encoding::UTF_8); pos += ln_size
          rp_size = b[pos, 4].unpack1("N"); pos += 4
          rp = b[pos, rp_size].force_encoding(Encoding::UTF_8); pos += rp_size
          mode, bytes_size = b[pos, 8].unpack("NN"); pos += 8
          bytes = b[pos, bytes_size]; pos += bytes_size
          { logical_name: ln, relative_path: rp, mode: mode, bytes: bytes }
        end
        records
      end

      private

      def write_string(io, str)
        bytes = str.b
        io << [bytes.bytesize].pack("N")
        io << bytes
      end
    end
  end
end
