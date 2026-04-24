# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require "tempfile"

module Uprb
  module RequireReplacer
    class << self
      attr_reader :mapping

      def pack(source_path, dest_path: nil, requires: [], dynamic: false, script_argv: [], skip_disable_gems: false, skip_ruby_path_replace: false)
        source = File.read(source_path)
        mapping = build_mapping(source_path, requires, dynamic, script_argv)
        embedded, external = build_payload(mapping)
        ruby_source = source_with_require_hook(source, requires)
        main_iseq = RubyVM::InstructionSequence.compile(ruby_source, source_path, source_path)
        payload = Marshal.dump({
          embedded: embedded,
          external: external,
          main: main_iseq.to_binary
        })

        shebang = resolve_shebang(source, skip_ruby_path_replace: skip_ruby_path_replace, skip_disable_gems: skip_disable_gems)
        wrapper = <<~RUBY
          #{shebang}
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

      def resolve_shebang(source, skip_ruby_path_replace:, skip_disable_gems:)
        if skip_ruby_path_replace
          first_line = source.lines.first&.chomp
          unless first_line&.start_with?("#!")
            raise Uprb::Error, "source has no shebang; --skip-ruby-path-replace requires one to preserve"
          end
          ruby_command = first_line[2..]
        else
          ruby_command = RbConfig.ruby
        end

        skip_disable_gems ? "#!#{ruby_command}" : "#!#{ruby_command} --disable-gems"
      end

      # `--dynamic` alone would miss literal requires in branches the
      # execution didn't take (rescued `LoadError` alternates, unused
      # autoloads, feature-flag branches); the static walk fills those in.
      def build_mapping(source_path, requires, dynamic, script_argv)
        return Uprb::StaticRequireTracker.trace(source_path, requires: requires) unless dynamic

        dynamic_map = execute_with_tracker(source_path, requires, script_argv)
        static_map = Uprb::StaticRequireTracker::StaticWalker.new.walk(File.expand_path(source_path))
        static_map.merge(dynamic_map)
      end

      def rewind_read_tempfile(file)
        file.flush
        file.rewind
        file.read
      end

      def execute_with_tracker(path, requires = [], script_argv = [])
        original_stdout, original_stderr = STDOUT.dup, STDERR.dup
        original_argv = ARGV.dup
        original_program_name = $PROGRAM_NAME
        tmp_stdout = Tempfile.new("uprb-stdout")
        tmp_stderr = Tempfile.new("uprb-stderr")
        mapping = nil

        begin
          STDOUT.reopen(tmp_stdout)
          STDERR.reopen(tmp_stderr)
          ARGV.replace(script_argv)
          $PROGRAM_NAME = path
          Uprb::RequireTracker.start
          requires.each {|lib| require lib }
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

      def source_with_require_hook(source, requires = [])
        preload_lines = requires.map {|lib| "require #{lib.inspect}" }.join("\n")
        pre_code = <<~RUBY
        module FixedRequire
          SUFFIXES = #{Uprb::SUFFIXES.inspect}.freeze

          def require(name)
            entry = EMBEDDED_ISEQ[name]
            if entry
              path, binary = entry
              return false if $LOADED_FEATURES.include?(path) || $LOADED_FEATURES.include?(name)
              $LOADED_FEATURES << path
              $LOADED_FEATURES << name unless $LOADED_FEATURES.include?(name)
              mark_runtime_resolved(name, path)
              RubyVM::InstructionSequence.load_from_binary(binary).eval
              true
            elsif (path = REQUIRE_MAP[name])
              result = super(path)
              mark_runtime_resolved(name, path) if result
              result
            else
              super(name)
            end
          end

          # C extensions bypass this hook via rb_require(); pre-mark the path
          # $LOAD_PATH would resolve `name` to so they see it as already loaded.
          def mark_runtime_resolved(name, loaded_path)
            resolved = $LOAD_PATH.lazy.flat_map {|d| SUFFIXES.map {|s| File.join(d, "\#{name}\#{s}") } }.find {|p| File.file?(p) }
            return unless resolved && resolved != loaded_path && !$LOADED_FEATURES.include?(resolved)
            $LOADED_FEATURES << resolved
          end
        end

        Kernel.prepend(FixedRequire)
        #{preload_lines}
        RUBY
        pre_code + source
      end

      def build_payload(mapping)
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
