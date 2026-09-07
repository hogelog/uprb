# frozen_string_literal: true

# Also embedded as source in native-bearing outputs. Keep this independent
# of RubyGems and native libraries (including digest).
module UprbRuntime
  module NativeSection
    VERSION = 1

    def self.encode(records)
      blob = [VERSION, records.size].pack("NN")
      records.each do |record|
        [record.fetch(:logical_name), record.fetch(:relative_path)].each do |value|
          blob << [value.bytesize].pack("N") << value.b
        end
        bytes = record.fetch(:bytes)
        blob << [record.fetch(:mode) & 0o777, bytes.bytesize].pack("NN") << bytes.b
      end
      blob
    end

    # Index file contents without copying them on every warm-cache startup.
    def self.index(blob)
      offset = 0
      read = lambda do |length|
        raise ArgumentError, "truncated native section" if offset + length > blob.bytesize
        value = blob.byteslice(offset, length)
        offset += length
        value
      end
      integer = -> { read.call(4).unpack1("N") }
      raise ArgumentError, "unsupported native section version" unless integer.call == VERSION

      files = {}
      count = integer.call
      count.times do
        read.call(integer.call) # logical name; requires use the separate manifest
        path = read.call(integer.call).force_encoding(Encoding::UTF_8)
        unless path.valid_encoding? && !path.match?(/[\\\x00]/) &&
            path.split("/", -1).none? { |part| part.empty? || part == "." || part == ".." }
          raise ArgumentError, "invalid native section path: #{path.inspect}"
        end
        raise ArgumentError, "duplicate native section path: #{path.inspect}" if files.key?(path)
        mode, length = integer.call, integer.call
        raise ArgumentError, "invalid native file mode" unless (mode & ~0o777).zero?
        raise ArgumentError, "truncated native section" if offset + length > blob.bytesize
        files[path] = [mode, offset, length]
        offset += length
      end
      raise ArgumentError, "trailing native section data" unless offset == blob.bytesize
      files
    end
  end
end
