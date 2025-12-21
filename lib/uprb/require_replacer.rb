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

      def pack_iseq(source_path, dest_path)
        unless defined?(RubyVM::InstructionSequence)
          raise Uprb::Error, "RubyVM::InstructionSequence unavailable"
        end

        source = File.read(source_path)
        mapping = capture_mapping(source)
        embedded, external = build_iseq_payload(mapping)
        ruby_source = source_with_iseq_require_hook(source)
        main_iseq = RubyVM::InstructionSequence.compile(ruby_source, source_path, source_path)
        payload = Marshal.dump({
          "embedded" => embedded,
          "external" => external,
          "main" => main_iseq.to_binary
        })

        wrapper = <<~RUBY
        #!#{RbConfig.ruby} --disable-gems
        DATA.binmode
        payload = DATA.read
        data = Marshal.load(payload)

        EMBEDDED_ISEQ = data.fetch("embedded")
        REQUIRE_MAP = data.fetch("external")

        iseq = RubyVM::InstructionSequence.load_from_binary(data.fetch("main"))
        iseq.eval
        __END__
        RUBY

        File.open(dest_path, "wb") do |file|
          file.write(wrapper)
          file.write(payload)
        end
        FileUtils.chmod("+x", dest_path)
        wrapper
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
        shebang = "#!#{RbConfig.ruby} --disable-gems\n"
        shebang + source_with_require_hook(source, mapping)
      end

      def source_with_require_hook(source, mapping)
        pre_code = <<~CODE
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

      def source_with_iseq_require_hook(source)
        pre_code = <<~CODE
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
        #{ RUBYGEMS_REQUIRED.map{ %[require "#{it}"] }.join("\n") }
        CODE
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
