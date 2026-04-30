# frozen_string_literal: true
#
# Template embedded into packed outputs by Uprb::RequireReplacer.pack.
# Loaded as text and substituted at pack time; do NOT `require` this file.
# See `render_bootstrap` in require_replacer.rb for the substitution markers.
#
Warning[:experimental] = false

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

# `tmpdir` triggers `require "etc"` (and thus loads the Etc C extension),
# which would leak into the user script's view. Pull it in only when the
# primary XDG/HOME candidate fails.
candidates = Enumerator.new do |y|
  if cache_override
    y << cache_override
  else
    xdg = ENV["XDG_CACHE_HOME"]
    y << File.join(xdg && !xdg.empty? ? xdg : File.join(Dir.home, ".cache"), "uprb")
    require "tmpdir"
    y << File.join(Dir.tmpdir, "uprb-#{Process.uid}")
  end
end

cache_dir = nil
cache_errors = []
candidates.each do |c|
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
    # Probe noexec on Linux before extracting; surface a clear, actionable
    # error pointing at --cache-dir.
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
        # An existing hash_dir without READY indicates a corrupted prior
        # extraction (interrupted before atomic rename or READY write).
        # Remove and re-extract.
        FileUtils.rm_rf(hash_dir) if File.directory?(hash_dir)
        FileUtils.mkdir_p(tmp, mode: 0o700)

        buf = IO::Buffer.for(NATIVE_SECTION)
        offset = 0
        version = buf.get_value(:U32, offset); offset += 4
        if version != 1
          $stderr.puts("uprb: unsupported native section version: #{version}")
          exit 1
        end
        count = buf.get_value(:U32, offset); offset += 4
        count.times do
          ln_size = buf.get_value(:U32, offset); offset += 4
          offset += ln_size # logical_name not needed at extract time
          rp_size = buf.get_value(:U32, offset); offset += 4
          rp = buf.get_string(offset, rp_size); offset += rp_size
          mode = buf.get_value(:U32, offset); offset += 4
          bytes_size = buf.get_value(:U32, offset); offset += 4
          bytes = buf.get_string(offset, bytes_size); offset += bytes_size
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

module FixedRequire
  SUFFIXES = __UPRB_SUFFIXES__.freeze

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
  # pre-mark the path $LOAD_PATH would resolve `name` to so they see it as
  # already loaded and don't pull in the host copy of the .so.
  def mark_runtime_resolved(name, loaded_path)
    resolved = $LOAD_PATH.lazy.flat_map {|d| SUFFIXES.map {|s| File.join(d, "#{name}#{s}") } }.find {|p| File.file?(p) }
    return unless resolved && resolved != loaded_path && !$LOADED_FEATURES.include?(resolved)
    $LOADED_FEATURES << resolved
  end
end

Kernel.prepend(FixedRequire)
__UPRB_PRELOADS__

iseq = RubyVM::InstructionSequence.load_from_binary(data.fetch(:main))
iseq.eval
__END__
