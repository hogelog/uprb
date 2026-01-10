# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require "pp"
require "stringio"

module Uprb
  module RequireReplacer
    class << self
      attr_reader :mapping

      def pack(source_path, dest_path: nil)
        source = File.read(source_path)
        mapping = execute_with_tracker(source_path)
        ruby_source = source_with_require_hook(source, mapping)
        program = "#!#{RbConfig.ruby} --disable-gems\n" + ruby_source
        return program unless dest_path

        File.write(dest_path, program)
        FileUtils.chmod("+x", dest_path)
      end

      def pack_iseq(source_path, dest_path: nil)
        source = File.read(source_path)
        mapping = execute_with_tracker(source_path)
        embedded, external = build_iseq_payload(mapping)
        ruby_source = source_with_iseq_require_hook(source)
        main_iseq = RubyVM::InstructionSequence.compile(ruby_source, source_path, source_path)
        payload = Marshal.dump({
          embedded: embedded,
          external: external,
          main: main_iseq.to_binary
        })

        wrapper = <<~RUBY
           #!#{RbConfig.ruby} --disable-gems
           DATA.binmode
           payload = DATA.read
           data = Marshal.load(payload)

           EMBEDDED_ISEQ = data.fetch(:embedded)
           REQUIRE_MAP = data.fetch(:external)

           iseq = RubyVM::InstructionSequence.load_from_binary(data.fetch(:main))
           iseq.eval
           __END__
        RUBY

        program = wrapper + payload
        return program unless dest_path

        File.write(dest_path, program)
        FileUtils.chmod("+x", dest_path)
      end

      private

      def execute_with_tracker(path)
        Uprb::RequireTracker.start
        stdout, stderr = StringIO.new, StringIO.new
        original_stdout, original_stderr = $stdout, $stderr
        original_argv = ARGV.dup
        original_program_name = $PROGRAM_NAME
        $stdout, $stderr = stdout, stderr
        mapping = nil

        begin
          ARGV.replace([])
          $PROGRAM_NAME = path
          load path
        rescue SystemExit => e
        rescue StandardError => e
          message = ["execution failed: #{e.class}: #{e.message}"]
          message << "stdout: #{stdout.string}" unless stdout.string.empty?
          message << "stderr: #{stderr.string}" unless stderr.string.empty?
          raise Uprb::Error, message.join("\n")
        ensure
          $stdout = original_stdout
          $stderr = original_stderr
          ARGV.replace(original_argv)
          $PROGRAM_NAME = original_program_name
          mapping = Uprb::RequireTracker.stop
        end

        mapping
      end

      def source_with_require_hook(source, mapping)
        mapping_without_absolute = mapping.reject{|name, path| File.absolute_path?(name) }

        pre_code = <<~RUBY
        module FixedRequire
          REQUIRE_MAP = #{ mapping_without_absolute.pretty_inspect.chomp }.freeze

          def require(name)
            path = REQUIRE_MAP[name]
            if path
              $LOADED_FEATURES << name unless $LOADED_FEATURES.include?(name)
              begin
                super(path)
              rescue
                raise
              end
            else
              super(name)
            end
          end
        end

        Kernel.prepend(FixedRequire)
        RUBY
        pre_code + source
      end

      def source_with_iseq_require_hook(source)
        pre_code = <<~RUBY
        module FixedRequire
          def require(name)
            entry = EMBEDDED_ISEQ[name]
            if entry
              path, binary = entry
              return false if $LOADED_FEATURES.include?(path) || $LOADED_FEATURES.include?(name)
              $LOADED_FEATURES << path
              $LOADED_FEATURES << name unless $LOADED_FEATURES.include?(name)
              RubyVM::InstructionSequence.load_from_binary(binary).eval
              true
            elsif (path = REQUIRE_MAP[name])
              super(path)
            else
              super(name)
            end
          end
        end

        Kernel.prepend(FixedRequire)
        RUBY
        pre_code + source
      end

      def build_iseq_payload(mapping)
        embedded = {}
        external = {}

        mapping.each do |name, path|
          if path.is_a?(String) && File.file?(path) && File.extname(path) == ".rb"
            source = File.read(path)
            iseq = RubyVM::InstructionSequence.compile(source, path, path)
            embedded[name] = [path, iseq.to_binary]
          else
            external[name] = path
          end
        end

        [embedded, external]
      end
    end
  end
end
