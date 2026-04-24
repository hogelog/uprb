# frozen_string_literal: true

require "prism"
require "set"

module Uprb
  # Avoids running the entry's top-level code (CLI scripts often start
  # `App.start(ARGV)` at load time) while still letting dependencies load
  # normally so rubygems resolution, autoload registration, etc. happen.
  module StaticRequireTracker
    class << self
      def trace(source_path, requires: [])
        Tracer.new(requires: requires).trace(source_path)
      end
    end

    class Tracer
      def initialize(requires: [])
        @requires = requires
      end

      def trace(source_path)
        entry_path = File.expand_path(source_path)

        dynamic = dynamic_phase(entry_path)
        static = StaticWalker.new.walk(entry_path)

        static.merge(dynamic)
      end

      private

      def dynamic_phase(entry_path)
        Uprb::RequireTracker.start
        begin
          @requires.each {|lib| require(lib) }
          entry_dir = File.dirname(entry_path)
          extract_requires(entry_path).each do |kind, name|
            trigger(kind, name, entry_dir)
          end
        ensure
          mapping = Uprb::RequireTracker.stop
        end
        mapping
      end

      def trigger(kind, name, entry_dir)
        case kind
        when :require
          require(name)
        when :require_relative
          require(File.expand_path(name, entry_dir))
        end
      rescue LoadError
        # The packed output falls through to runtime require for names we
        # can't resolve here (e.g. local libs the entry would have added to
        # $LOAD_PATH if it had been allowed to run).
      end

      def extract_requires(path)
        source = File.read(path)
        result = Prism.parse(source, filepath: path)
        return [] if result.failure?

        visitor = RequireVisitor.new
        result.value.accept(visitor)
        visitor.requires
      end
    end

    class StaticWalker
      def initialize
        @mapping = {}
        @visited = Set.new
      end

      def walk(entry_path)
        parse_file(entry_path)
        @mapping
      end

      private

      def parse_file(path)
        return unless @visited.add?(path)
        return unless File.file?(path)

        source = File.read(path)
        result = Prism.parse(source, filepath: path)
        return if result.failure?

        visitor = RequireVisitor.new
        result.value.accept(visitor)

        visitor.requires.each do |kind, name|
          case kind
          when :require
            record_require(name)
          when :require_relative
            absolute = File.expand_path(name, File.dirname(path))
            resolved = resolve_file(absolute)
            next unless resolved

            @mapping[absolute] ||= resolved
            parse_file(resolved) if resolved.end_with?(".rb")
          end
        end
      end

      def record_require(name)
        resolved = resolve_in_load_path(name)
        return unless resolved

        @mapping[name] ||= resolved
        parse_file(resolved) if resolved.end_with?(".rb")
      end

      # Skips rubygems' pre-activation steps (default-gem / unresolved-dep
      # resolution) that run before the $LOAD_PATH search — so in environments
      # with multi-version conflicts this may pick a different version than
      # runtime would.
      def resolve_in_load_path(name)
        return resolve_file(name) if File.absolute_path?(name)

        resolved = search_load_path(name)
        return resolved if resolved

        return nil unless defined?(Gem) && Gem.respond_to?(:try_activate)
        return nil unless Gem.try_activate(name)

        search_load_path(name)
      end

      def search_load_path(name)
        $LOAD_PATH.each do |dir|
          candidate = resolve_file(File.join(dir, name))
          return candidate if candidate
        end
        nil
      end

      def resolve_file(path)
        extname = File.extname(path)
        if Uprb::SUFFIXES.include?(extname)
          if Uprb::DL_SUFFIXES.include?(extname)
            base = path.delete_suffix(extname)
            Uprb::DL_SUFFIXES.each do |suffix|
              candidate = "#{base}#{suffix}"
              return candidate if File.file?(candidate)
            end
            nil
          else
            File.file?(path) ? path : nil
          end
        else
          Uprb::SUFFIXES.each do |suffix|
            candidate = "#{path}#{suffix}"
            return candidate if File.file?(candidate)
          end
          nil
        end
      end
    end

    class RequireVisitor < Prism::Visitor
      attr_reader :requires

      def initialize
        super
        @requires = []
      end

      def visit_call_node(node)
        case node.name
        when :require, :require_relative
          if node.receiver.nil?
            name = extract_string_argument(node, index: 0)
            @requires << [node.name, name] if name
          end
        when :autoload
          name = extract_string_argument(node, index: 1)
          @requires << [:require, name] if name
        end
        super
      end

      private

      def extract_string_argument(node, index:)
        args = node.arguments&.arguments
        return nil unless args && args[index].is_a?(Prism::StringNode)

        args[index].unescaped
      end
    end
  end
end
