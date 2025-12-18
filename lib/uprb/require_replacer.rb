# frozen_string_literal: true

require "fileutils"
require "tempfile"
require "rbconfig"
require "pp"
require "stringio"

module Uprb
  module RequireReplacer
    class << self
      attr_reader :mapping

      RUBYGEMS_REQUIRED = %w[]

      def replace(source)
        recorded_mapping = capture_mapping(source)
        @mapping = recorded_mapping.dup
        rewrite_source(source, recorded_mapping)
      end

      def pack(source_path, dest_path)
        source = File.read(source_path)
        rewritten = replace(source)
        File.write(dest_path, rewritten)
        FileUtils.chmod("+x", dest_path)
        rewritten
      end

      private

      def capture_mapping(source)
        Tempfile.create(["uprb-src", ".rb"]) do |file|
          file.write(source)
          file.flush
          execute_with_tracker(file.path)
        end
      end

      def execute_with_tracker(path)
        Uprb::RequireTracker.start
        stdout, stderr = StringIO.new, StringIO.new
        original_stdout, original_stderr = $stdout, $stderr
        $stdout, $stderr = stdout, stderr
        mapping = nil

        begin
          RUBYGEMS_REQUIRED.each { require it }
          load path
        rescue StandardError => e
          message = ["execution failed: #{e.class}: #{e.message}"]
          message << "stdout:\n#{stdout.string}" unless stdout.string.empty?
          message << "stderr:\n#{stderr.string}" unless stderr.string.empty?
          raise Uprb::Error, message.join("\n")
        ensure
          $stdout = original_stdout
          $stderr = original_stderr
          mapping = Uprb::RequireTracker.stop
        end

        mapping
      end

      def rewrite_source(source, mapping)
        pre_code = <<~CODE
        #!#{RbConfig.ruby} --disable-gems
        module FixedRequire
          REQUIRE_MAP = #{ mapping.pretty_inspect }.freeze

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
        #{ RUBYGEMS_REQUIRED.map{ %[require "#{it}"] }.join("\n") }
        CODE
        pre_code + source
      end
    end
  end
end
