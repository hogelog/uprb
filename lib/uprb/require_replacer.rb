# frozen_string_literal: true

require "fileutils"
require "digest"
require "rbconfig"
require "tempfile"

module Uprb
  module RequireReplacer
    BUILTIN_FEATURES = $LOADED_FEATURES.reject { |path| path.include?(File::SEPARATOR) }.freeze

    class << self
      attr_reader :mapping

      def pack(source_path, dest_path: nil, requires: [], dynamic: false, script_argv: [], skip_disable_gems: false, skip_ruby_path_replace: false)
        source = File.read(source_path)
        mapping = build_mapping(source_path, requires, dynamic, script_argv)
        data = build_payload(mapping)
        main_iseq = RubyVM::InstructionSequence.compile(source, source_path, source_path)
        data[:main] = main_iseq.to_binary

        shebang = resolve_shebang(source, skip_ruby_path_replace: skip_ruby_path_replace, skip_disable_gems: skip_disable_gems)
        program = String.new(encoding: Encoding::BINARY)
        program << "#{shebang}\n".b if shebang
        program << render_bootstrap(requires, native: data.key?(:native)).b
        program << Marshal.dump(data)
        return program unless dest_path

        File.binwrite(dest_path, program)
        FileUtils.chmod("+x", dest_path) if shebang
      end

      private

      def resolve_shebang(source, skip_ruby_path_replace:, skip_disable_gems:)
        first_line = source.lines.first&.chomp
        return nil unless first_line&.start_with?("#!")

        ruby_command = skip_ruby_path_replace ? first_line[2..] : RbConfig.ruby
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

      def render_bootstrap(requires, native:)
        body = +"DATA.binmode\ndata = Marshal.load(DATA)\n"
        body << File.read(File.join(__dir__, "require_hook.rb")).sub("__UPRB_SUFFIXES__", Uprb::SUFFIXES.inspect)
        body << "\nUprbRuntime::EMBEDDED_ISEQ = data.fetch(:embedded)\n"
        if native
          body << File.read(File.join(__dir__, "native_section.rb"))
          body << File.read(File.join(__dir__, "native_cache.rb"))
          body << <<~RUBY
            begin
              UprbRuntime::NATIVE_MAP = UprbRuntime::NativeCache.new(data.fetch(:native)).resolve
            rescue UprbRuntime::NativeCache::Error, SystemCallError, ArgumentError => e
              warn "uprb: \#{e.message}"
              exit 1
            end
          RUBY
        end
        body << "Kernel.prepend(UprbRuntime::NativeRequire)\n" if native
        body << "Kernel.prepend(UprbRuntime::FixedRequire)\n"
        requires.each { |lib| body << "require #{lib.inspect}\n" }
        body << "RubyVM::InstructionSequence.load_from_binary(data.fetch(:main)).eval\n__END__\n"
      end

      def build_payload(mapping)
        embedded = {}
        natives = {}

        mapping.each do |name, path|
          unless path.is_a?(String)
            raise Uprb::Error, "unsupported require mapping for #{name.inspect}: #{path.inspect}"
          end
          # Only real built-ins may fall through without an on-disk file.
          next if BUILTIN_FEATURES.include?(path)
          unless File.absolute_path?(path) && File.file?(path)
            raise Uprb::Error, "cannot bundle require #{name.inspect}: #{path.inspect} is not an existing absolute file"
          end

          if File.extname(path) == ".rb"
            source = File.read(path)
            iseq = RubyVM::InstructionSequence.compile(source, path, path)
            entry = [path, iseq.to_binary]
            feature_aliases(name, path).each { |feature| embedded[feature] ||= entry }
          elsif Uprb::DL_SUFFIXES.include?(File.extname(path))
            natives[name] = path
          else
            raise Uprb::Error, "unsupported require shape for #{name.inspect}: #{path} (expected .rb or native extension)"
          end
        end

        data = { embedded: embedded }
        data[:native] = build_native_payload(natives) unless natives.empty?
        data
      end

      def feature_aliases(name, path)
        base = Uprb::SUFFIXES.include?(File.extname(name)) ? name.delete_suffix(File.extname(name)) : name
        suffixes = File.extname(path) == ".rb" ? [".rb"] : Uprb::DL_SUFFIXES
        ([name, path, path.delete_suffix(File.extname(path)), base] + suffixes.map { |suffix| "#{base}#{suffix}" }).uniq
      end

      def build_native_payload(natives)
        records = []
        manifest = {}
        # Keep siblings together for $ORIGIN / @loader_path dependencies.
        # Order by logical names so moving an identical source tree does
        # not change the native section hash.
        groups = natives.group_by { |_name, path| File.dirname(path) }
        groups.values.sort_by { |entries| entries.map { |name, _| name }.sort }.each_with_index do |entries, index|
          primaries = entries.map(&:last).uniq
          directory = File.dirname(primaries.first)
          files = primaries + companion_files(directory, primaries)
          files.uniq.sort.each do |path|
            relative = "#{index}/#{path.delete_prefix("#{directory}/")}"
            records << { logical_name: relative, relative_path: relative,
              mode: File.stat(path).mode, bytes: File.binread(path) }
          end
          entries.each do |name, path|
            feature_aliases(name, path).each do |feature|
              manifest[feature] ||= "#{index}/#{File.basename(path)}"
            end
          end
        end
        section = UprbRuntime::NativeSection.encode(records.sort_by { |record| record[:relative_path] })
        { section: section, hash: Digest::SHA256.hexdigest(section), manifest: manifest }
      end

      def companion_files(directory, primaries)
        return [] unless primaries.any? { |path| File.basename(path, ".*") == File.basename(directory) }

        # Only scan the extension's own directory, never the whole Ruby
        # installation. Ruby sources still go through ISeq compilation.
        Dir.glob("**/*", File::FNM_DOTMATCH, base: directory).filter_map do |relative|
          path = File.join(directory, relative)
          next unless File.file?(path)
          next if path.end_with?(".rb") || primaries.include?(path)
          unless File.realpath(path).start_with?("#{File.realpath(directory)}/")
            raise Uprb::Error, "native companion escapes its directory: #{path}"
          end
          path
        end
      end
    end
  end
end
