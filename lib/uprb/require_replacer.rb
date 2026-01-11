# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require "pp"
require "stringio"
require "tempfile"

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
           data = Marshal.load(DATA)

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

      def rewind_read_tempfile(file)
        file.flush
        file.rewind
        file.read
      end

      def execute_with_tracker(path)
        original_stdout, original_stderr = STDOUT.dup, STDERR.dup
        original_argv = ARGV.dup
        original_program_name = $PROGRAM_NAME
        tmp_stdout = Tempfile.new("uprb-stdout")
        tmp_stderr = Tempfile.new("uprb-stderr")
        mapping = nil

        begin
          STDOUT.reopen(tmp_stdout)
          STDERR.reopen(tmp_stderr)
          ARGV.replace([])
          $PROGRAM_NAME = path
          Uprb::RequireTracker.start
          load path
        rescue SystemExit => e
        rescue StandardError => e
          stdout_content = rewind_read_tempfile(tmp_stdout)
          stderr_content = rewind_read_tempfile(tmp_stderr)
          message = ["execution failed: #{e.class}: #{e.message}"]
          message << "stdout: #{stdout_content}" unless stdout_content.empty?
          message << "stderr: #{stderr_content}" unless stderr_content.empty?
          raise Uprb::Error, message.join("\n")
        ensure
          mapping = Uprb::RequireTracker.stop
          STDOUT.reopen(original_stdout)
          STDERR.reopen(original_stderr)
          ARGV.replace(original_argv)
          $PROGRAM_NAME = original_program_name
          tmp_stdout.close!
          tmp_stderr.close!
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
