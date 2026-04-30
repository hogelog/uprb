# frozen_string_literal: true

require "digest"
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
        embedded, native_records, native_manifest = build_payload(mapping)
        native_section = Uprb::NativeSection.encode(native_records)
        native_hash = Digest::SHA256.hexdigest(native_section)
        ruby_source = source_with_require_hook(source, requires)
        main_iseq = RubyVM::InstructionSequence.compile(ruby_source, source_path, source_path)
        payload = Marshal.dump({
          embedded: embedded,
          native_section: native_section,
          native_manifest: native_manifest,
          native_hash: native_hash,
          main: main_iseq.to_binary,
        })

        shebang = resolve_shebang(source, skip_ruby_path_replace: skip_ruby_path_replace, skip_disable_gems: skip_disable_gems)
        body = bootstrap_body

        program = String.new(encoding: Encoding::BINARY)
        program << "#{shebang}\n".b if shebang
        program << body.b
        program << payload

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

          # C extensions may bypass this Kernel#require hook via rb_require();
          # pre-mark the path $LOAD_PATH would resolve `name` to so they see it
          # as already loaded and don't pull in the host copy of the .so.
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

      # Partition the require mapping into:
      #   - embedded ISeqs for `.rb` sources
      #   - native records bundled into the payload's native section
      #   - manifest entries pointing logical require names at cache-relative
      #     paths inside the extracted hash directory
      #
      # A required path that is neither `.rb` nor a recognized native
      # extension shape (an absolute path to a `.so`/`.dylib`/`.bundle` file
      # that exists, or a bare statically-linked feature like `enumerator.so`
      # which is dropped from the maps and resolved by Ruby itself) is a
      # hard error.
      def build_payload(mapping)
        embedded = {}
        # Two-pass: first collect all native source paths by their require
        # name, then assign deterministic relative paths so the encoded
        # native section contains no host-specific absolute paths.
        native_sources = {} # logical_name => absolute_path
        manifest = {}

        mapping.each do |name, value|
          unless value.is_a?(String)
            raise Uprb::Error, "uprb: unsupported require mapping for #{name.inspect}: #{value.inspect}"
          end

          if File.absolute_path?(value) && File.file?(value)
            ext = File.extname(value)
            case
            when ext == ".rb"
              source = File.read(value)
              iseq = RubyVM::InstructionSequence.compile(source, value, value)
              embedded[name] = [value, iseq.to_binary]
            when Uprb::DL_SUFFIXES.include?(ext)
              native_sources[name] = value
            else
              raise Uprb::Error, "uprb: unsupported require shape for #{name.inspect}: #{value} (only .rb and native extensions are supported)"
            end
          elsif !File.absolute_path?(value) && Uprb::SUFFIXES.include?(File.extname(value))
            # Bare-name $LOADED_FEATURES entry such as "enumerator.so"
            # (statically linked into the Ruby binary) or "set.rb" (a
            # default gem that records a bare filename rather than an
            # absolute path). Drop from both maps so the runtime hook
            # falls through to super and Ruby resolves it itself.
            next
          else
            raise Uprb::Error, "uprb: cannot bundle require #{name.inspect}: #{value} (path is not a .rb or native extension file)"
          end
        end

        # All source dirs that hold a primary .so + their companion files.
        # Companions are sibling files inside `ext/<name>/` or `lib/<name>/`
        # — directories whose basename matches the .so's basename. Sibling
        # `.rb` files are skipped (they are tracked through the ISeq map).
        files_by_dir = {}
        native_sources.each_value do |path|
          (files_by_dir[File.dirname(path)] ||= []) << path
        end
        files_by_dir.each_key do |dir|
          companion_dir_files(dir, files_by_dir[dir]).each do |c|
            files_by_dir[dir] << c unless files_by_dir[dir].include?(c)
          end
        end

        # Stable ordering: sort dirs alphabetically and assign sequential
        # indices. relative_path = `<index>/<basename>` carries no host
        # path — only the numeric index and the basename. This keeps the
        # encoded section free of `/usr/lib`-style paths.
        records = []
        path_to_relative = {}
        files_by_dir.keys.sort.each_with_index do |dir, idx|
          files_by_dir[dir].uniq.sort.each do |path|
            rel = "#{idx}/#{File.basename(path)}"
            path_to_relative[path] = rel
            stat = File.stat(path)
            records << {
              logical_name: rel,
              relative_path: rel,
              mode: stat.mode,
              bytes: File.binread(path),
            }
          end
        end

        native_sources.each do |name, abs|
          manifest[name] = path_to_relative.fetch(abs)
        end

        # Sort records by relative_path for hash stability.
        records.sort_by! { |r| r[:relative_path] }

        [embedded, records, manifest]
      end

      def companion_dir_files(dir, primaries)
        base_names = primaries.map { |p| File.basename(p, ".*") }
        return [] unless base_names.any? { |b| b == File.basename(dir) }

        Dir.children(dir).filter_map do |entry|
          path = File.join(dir, entry)
          next unless File.file?(path)
          next if File.extname(path) == ".rb"
          next if primaries.include?(path)
          path
        end
      end

      def bootstrap_body
        <<~'RUBY'
          DATA.binmode
          data = Marshal.load(DATA)

          EMBEDDED_ISEQ = data.fetch(:embedded)
          NATIVE_SECTION = data.fetch(:native_section)
          NATIVE_MANIFEST = data.fetch(:native_manifest)
          NATIVE_HASH = data.fetch(:native_hash)

          require "fileutils"

          cache_override = nil
          if ARGV[0] == "--cache-dir" && ARGV[2] == "--"
            cache_override = ARGV[1]
            ARGV.replace(ARGV[3..] || [])
          end

          # Lazy-pull tmpdir only when the primary XDG/HOME candidate fails.
          # `require "tmpdir"` triggers `require "etc"` (and thus loads the
          # Etc C extension), which would leak into the user script's view.
          enumerate_candidates = lambda do
            if cache_override
              return Enumerator.new { |y| y << cache_override }
            end
            Enumerator.new do |y|
              xdg = ENV["XDG_CACHE_HOME"]
              y << File.join(xdg && !xdg.empty? ? xdg : File.join(Dir.home, ".cache"), "uprb")
              require "tmpdir"
              y << File.join(Dir.tmpdir, "uprb-#{Process.uid}")
            end
          end

          cache_dir = nil
          cache_errors = []
          enumerate_candidates.call.each do |c|
            begin
              FileUtils.mkdir_p(c, mode: 0o700)
              cache_dir = c
              break
            rescue SystemCallError => e
              cache_errors << [c, e]
            end
          end

          if cache_dir.nil?
            $stderr.puts("uprb: no writable cache directory; tried:")
            cache_errors.each { |c, e| $stderr.puts("  #{c}: #{e.class}: #{e.message}") }
            exit 1
          end

          hash_dir = File.join(cache_dir, NATIVE_HASH)
          ready = File.join(hash_dir, "READY")

          unless File.exist?(ready)
            if NATIVE_MANIFEST.empty?
              FileUtils.mkdir_p(hash_dir, mode: 0o700)
              File.binwrite(ready, "")
            else
              # Probe noexec on Linux before extracting; surface a clear,
              # actionable error pointing at --cache-dir.
              if File.exist?("/proc/mounts")
                begin
                  abs = File.absolute_path(cache_dir)
                  best_mp = nil
                  best_opts = nil
                  File.foreach("/proc/mounts") do |line|
                    parts = line.split
                    next if parts.size < 4
                    mp = parts[1]
                    if abs == mp || abs.start_with?(mp == "/" ? "/" : "#{mp}/")
                      if best_mp.nil? || mp.length > best_mp.length
                        best_mp = mp
                        best_opts = parts[3]
                      end
                    end
                  end
                  if best_opts && best_opts.split(",").include?("noexec")
                    $stderr.puts("uprb: cache directory #{cache_dir.inspect} is on a noexec mount; pass --cache-dir DIR -- to choose a different cache location")
                    exit 1
                  end
                rescue SystemCallError
                  # /proc/mounts unreadable — skip the probe.
                end
              end

              lockfile = File.join(cache_dir, "#{NATIVE_HASH}.lock")
              File.open(lockfile, File::RDWR | File::CREAT, 0o600) do |f|
                f.flock(File::LOCK_EX)
                unless File.exist?(ready)
                  tmp = "#{hash_dir}.tmp"
                  FileUtils.rm_rf(tmp)
                  # An existing hash_dir without READY indicates a corrupted
                  # prior extraction (interrupted before atomic rename or
                  # READY write). Remove and re-extract.
                  FileUtils.rm_rf(hash_dir) if File.directory?(hash_dir)
                  FileUtils.mkdir_p(tmp, mode: 0o700)

                  blob = NATIVE_SECTION
                  pos = 0
                  version, count = blob[pos, 8].unpack("NN")
                  pos += 8
                  if version != 1
                    $stderr.puts("uprb: unsupported native section version: #{version}")
                    exit 1
                  end
                  count.times do
                    ln_size = blob[pos, 4].unpack1("N"); pos += 4
                    pos += ln_size # logical_name not needed at extract time
                    rp_size = blob[pos, 4].unpack1("N"); pos += 4
                    rp = blob[pos, rp_size]; pos += rp_size
                    mode, bytes_size = blob[pos, 8].unpack("NN"); pos += 8
                    bytes = blob[pos, bytes_size]; pos += bytes_size
                    target = File.join(tmp, rp)
                    FileUtils.mkdir_p(File.dirname(target))
                    File.binwrite(target, bytes)
                    File.chmod(mode & 0o777, target)
                  end

                  File.binwrite(File.join(tmp, "READY"), "")
                  File.rename(tmp, hash_dir)
                end
              end
            end
          end

          REQUIRE_MAP = NATIVE_MANIFEST.transform_values { |rp| File.join(hash_dir, rp) }.freeze

          iseq = RubyVM::InstructionSequence.load_from_binary(data.fetch(:main))
          iseq.eval
          __END__
        RUBY
      end
    end
  end
end
