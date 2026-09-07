# frozen_string_literal: true

# Template included in every packed output; loaded as text at pack time.
module UprbRuntime
  module FixedRequire
    SUFFIXES = __UPRB_SUFFIXES__.freeze

    def require(name)
      name = File.path(name)
      entry = UprbRuntime::EMBEDDED_ISEQ[name]
      return super(name) unless entry

      path, binary = entry
      return false if $LOADED_FEATURES.include?(path)
      added = [path, name].uniq.reject { |feature| $LOADED_FEATURES.include?(feature) }
      $LOADED_FEATURES.concat(added)
      resolved = uprb_mark_runtime_resolved(name, path)
      added << resolved if resolved
      begin
        RubyVM::InstructionSequence.load_from_binary(binary).eval
      rescue Exception
        added.each { |feature| $LOADED_FEATURES.delete(feature) }
        raise
      end
      true
    end

    def require_relative(name)
      location = caller_locations(1, 1).first
      path = location.absolute_path || location.path
      Kernel.instance_method(:require).bind_call(self, File.expand_path(File.path(name), File.dirname(path)))
    end

    # C extensions can call rb_require directly. Mark the host alias of an
    # already loaded feature so they don't initialize a second copy.
    def uprb_mark_runtime_resolved(name, loaded_path)
      base = SUFFIXES.any? { |suffix| name.end_with?(suffix) } ? name.delete_suffix(File.extname(name)) : name
      suffixes = File.extname(loaded_path) == ".rb" ? [".rb"] : SUFFIXES.reject { |suffix| suffix == ".rb" }
      resolved = $LOAD_PATH.lazy.flat_map { |dir| suffixes.map { |suffix| File.join(dir, "#{base}#{suffix}") } }.find { |path| File.file?(path) }
      return unless resolved && resolved != loaded_path && !$LOADED_FEATURES.include?(resolved)
      $LOADED_FEATURES << resolved
      resolved
    end

    private :require, :require_relative, :uprb_mark_runtime_resolved
  end
end
