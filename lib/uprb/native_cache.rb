# frozen_string_literal: true

# Embedded only in outputs containing native files.
require "fileutils"

module UprbRuntime
  class NativeCache
    class Error < StandardError; end
    class NoexecError < Error; end

    def initialize(native)
      @blob = native.fetch(:section)
      @hash = native.fetch(:hash)
      @manifest = native.fetch(:manifest)
      raise Error, "invalid native cache hash" unless @hash.match?(/\A[0-9a-f]{64}\z/)
      @files = NativeSection.index(@blob)
      @directories = @files.keys.flat_map do |path|
        parents = []
        while (path = File.dirname(path)) != "."
          parents << path
        end
        parents
      end.uniq
      unless @manifest.values.all? { |path| @files.key?(path) }
        raise Error, "invalid native manifest"
      end
    end

    def resolve
      errors = []
      candidates(errors).each do |candidate|
        begin
          root = File.expand_path(candidate)
          directory = prepare(root)
          return @manifest.transform_values { |path| File.join(directory, path) }.freeze
        rescue NoexecError
          raise
        rescue SystemCallError, Error => e
          errors << "#{candidate.inspect}: #{e.class}: #{e.message}"
        end
      end
      raise Error, "no usable native cache directory; tried #{errors.join('; ')}; set RUBY_UPRB_CACHE_DIR"
    end

    private

    def candidates(errors)
      Enumerator.new do |paths|
        override = ENV["RUBY_UPRB_CACHE_DIR"]
        paths << override if override && !override.empty?
        xdg = ENV["XDG_CACHE_HOME"]
        if xdg && !xdg.empty?
          paths << File.join(xdg, "uprb")
        else
          begin
            paths << File.join(Dir.home, ".cache", "uprb")
          rescue ArgumentError => e
            errors << "home cache: #{e.message}"
          end
        end
        begin
          paths << File.join(temporary_directory, "uprb-#{Process.uid}")
        rescue ArgumentError => e
          errors << "temporary cache: #{e.message}"
        end
      end
    end

    # The Unix Dir.tmpdir search, without requiring tmpdir/its etc extension
    # before the bundled extensions are available.
    def temporary_directory
      [ENV["TMPDIR"], ENV["TMP"], ENV["TEMP"], "/tmp", "."].compact.each do |path|
        next if path.empty?
        begin
          stat = File.stat(path)
          next unless stat.directory? && File.writable?(path)
          next if stat.world_writable? && !stat.sticky?
          return File.expand_path(path)
        rescue SystemCallError
          next
        end
      end
      raise ArgumentError, "could not find a temporary directory"
    end

    def prepare(root)
      FileUtils.mkdir_p(root, mode: 0o700)
      stat = File.lstat(root)
      unless stat.directory? && stat.uid == Process.euid && (stat.mode & 0o022).zero?
        raise Error, "cache root must be an owned directory without group/other write access"
      end

      directory = File.join(root, @hash)
      return directory if valid?(directory)

      flags = File::RDWR | File::CREAT | File::NOFOLLOW
      File.open(File.join(root, "#{@hash}.lock"), flags, 0o600) do |lock|
        unless lock.stat.file? && lock.stat.uid == Process.euid && lock.stat.nlink == 1
          raise Error, "invalid native cache lock file"
        end
        lock.flock(File::LOCK_EX)
        return directory if valid?(directory)
        check_noexec(root)

        if intact?(directory)
          write_ready(directory)
        else
          extract(directory)
        end
      end
      directory
    end

    # READY is plain text, never deserialized as executable Ruby objects.
    # ctime catches same-size edits even when mtime is restored. Changed
    # attributes trigger byte-for-byte verification against the payload.
    def signature(directory)
      root = File.lstat(directory)
      return unless root.directory? && (root.mode & 0o777) == 0o700
      return unless @directories.all? { |path| File.lstat(File.join(directory, path)).directory? }
      @files.map do |path, (mode, _offset, length)|
        stat = File.lstat(File.join(directory, path))
        return unless stat.file? && stat.size == length && (stat.mode & 0o777) == mode
        [stat.dev, stat.ino, stat.mode, stat.size,
          stat.mtime.to_i, stat.mtime.nsec, stat.ctime.to_i, stat.ctime.nsec].join(":")
      end.join("\n")
    rescue Errno::ENOENT, Errno::ENOTDIR
      nil
    end

    def valid?(directory)
      current = signature(directory)
      current && File.lstat(File.join(directory, "READY")).file? &&
        File.binread(File.join(directory, "READY")) == current
    rescue Errno::ENOENT, Errno::ENOTDIR
      false
    end

    def intact?(directory)
      return false unless signature(directory)
      @files.all? do |path, (_mode, offset, length)|
        File.binread(File.join(directory, path)) == @blob.byteslice(offset, length)
      end
    end

    def write_ready(directory)
      ready = File.join(directory, "READY")
      File.open("#{ready}.tmp", File::WRONLY | File::CREAT | File::TRUNC | File::NOFOLLOW, 0o600) do |file|
        file.write(signature(directory))
      end
      File.rename("#{ready}.tmp", ready)
    end

    def extract(directory)
      temporary = "#{directory}.tmp"
      FileUtils.rm_rf(temporary)
      FileUtils.mkdir_p(temporary, mode: 0o700)
      File.chmod(0o700, temporary)
      begin
        @files.each do |path, (mode, offset, length)|
          target = File.join(temporary, path)
          FileUtils.mkdir_p(File.dirname(target), mode: 0o700)
          File.binwrite(target, @blob.byteslice(offset, length))
          File.chmod(mode, target)
        end
        write_ready(temporary)
        FileUtils.rm_rf(directory)
        File.rename(temporary, directory)
      ensure
        FileUtils.rm_rf(temporary)
      end
    end

    def check_noexec(root)
      return unless File.file?("/proc/mounts")
      actual = File.realpath(root)
      mounts = File.readlines("/proc/mounts").filter_map do |line|
        _device, mount, _type, options = line.split
        next unless mount && options
        mount = mount.gsub(/\\([0-7]{3})/) { $1.to_i(8).chr }
        next unless actual == mount || actual.start_with?(mount.end_with?("/") ? mount : "#{mount}/")
        [mount, options]
      end
      mount, options = mounts.max_by { |path, _opts| path.length }
      if options && options.split(",").include?("noexec")
        raise NoexecError, "native cache #{root.inspect} is on noexec mount #{mount.inspect}; set RUBY_UPRB_CACHE_DIR to an executable filesystem"
      end
    rescue Errno::ENOENT, Errno::EACCES
      # Some environments do not expose mount information. dlopen will
      # still report failures through NativeRequire below.
    end
  end

  module NativeRequire
    def require(name)
      name = File.path(name)
      path = UprbRuntime::NATIVE_MAP[name]
      return super(name) unless path

      result = super(path)
      uprb_mark_runtime_resolved(name, path) if result
      result
    rescue LoadError => e
      raise unless path
      raise LoadError, "#{e.message} (bundled native extension; check RUBY_UPRB_CACHE_DIR and Ruby/system-library ABI compatibility)", e.backtrace
    end

    private :require
  end
end
