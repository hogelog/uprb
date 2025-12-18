# frozen_string_literal: true

require "fileutils"
require_relative "../uprb"

module Uprb
  class CLI
    USAGE = "Usage: uprb pack <src.rb> <dest>"

    def self.start(argv = ARGV, stdout: $stdout, stderr: $stderr)
      new(argv, stdout: stdout, stderr: stderr).run
    end

    def initialize(argv, stdout:, stderr:)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
    end

    def run
      command = @argv.shift

      case command
      when "pack"
        pack_command
      when "--version", "-v"
        @stdout.puts(Uprb::VERSION)
        0
      when "--help", "-h", nil
        @stdout.puts(USAGE)
        command.nil? ? 1 : 0
      else
        @stderr.puts(USAGE)
        1
      end
    rescue Uprb::Error => e
      @stderr.puts("uprb: #{e.message}")
      1
    rescue StandardError => e
      @stderr.puts("uprb: #{e.class}: #{e.message}")
      1
    end

    private

    def pack_command
      src = @argv.shift or raise Uprb::Error, "missing <src.rb>"
      dest = @argv.shift or raise Uprb::Error, "missing <dist>"
      raise Uprb::Error, "unexpected arguments: #{@argv.join(' ')}" unless @argv.empty?

      src_path = File.expand_path(src)
      dest_path = File.expand_path(dest)

      raise Uprb::Error, "source not found: #{src}" unless File.file?(src_path)

      FileUtils.mkdir_p(File.dirname(dest_path))
      Uprb::RequireReplacer.pack(src_path, dest_path)

      @stdout.puts("Packed #{dest_path}")
      0
    end
  end
end
