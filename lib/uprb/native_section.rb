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
      # Records are emitted in the given order; callers should sort by
      # relative_path for hash stability.
      def encode(records)
        out = String.new(encoding: Encoding::BINARY)
        out << [VERSION, records.size].pack("NN")
        records.each do |r|
          write_string(out, r.fetch(:logical_name))
          write_string(out, r.fetch(:relative_path))
          out << [r.fetch(:mode) & 0xFFFFFFFF, r.fetch(:bytes).bytesize].pack("NN")
          out << r.fetch(:bytes).b
        end
        out
      end

      def decode(blob)
        b = blob.b
        offset = 0
        version, count = b[offset, 8].unpack("NN")
        offset += 8
        raise Uprb::Error, "unsupported native section version: #{version}" unless version == VERSION

        Array.new(count) do
          ln_size = b[offset, 4].unpack1("N"); offset += 4
          ln = b[offset, ln_size].force_encoding(Encoding::UTF_8); offset += ln_size
          rp_size = b[offset, 4].unpack1("N"); offset += 4
          rp = b[offset, rp_size].force_encoding(Encoding::UTF_8); offset += rp_size
          mode, bytes_size = b[offset, 8].unpack("NN"); offset += 8
          bytes = b[offset, bytes_size]; offset += bytes_size
          { logical_name: ln, relative_path: rp, mode: mode, bytes: bytes }
        end
      end

      private

      def write_string(out, str)
        bytes = str.b
        out << [bytes.bytesize].pack("N")
        out << bytes
      end
    end
  end
end
