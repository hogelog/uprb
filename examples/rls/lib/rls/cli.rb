module Rls
  class CLI
    USAGE = <<~USAGE.chomp
    Usage:
      rls [path]
    USAGE

    class << self
      def start(argv)
        new(argv).start
      end
    end

    def initialize(argv)
      @argv = argv.dup
    end

    def start
      arg = @argv.shift

      case arg
      when "--help", "-h"
        STDOUT.puts(USAGE)
      when nil
        ls_command
      else
        ls_command(arg)
      end
    rescue Rls::Error => e
      STDERR.puts("rls: #{e.message}")
    rescue StandardError => e
      STDERR.puts("rls: #{e.class}: #{e.message}")
    end

    private

    def ls_command(path = ".")
      raise Rls::Error, "unexpected arguments: #{@argv.join(' ')}" unless @argv.empty?

      abs_path = File.expand_path(path)
      raise Rls::Error, "not a directory: #{path}" unless File.directory?(abs_path)

      Dir.children(abs_path).sort.each do |entry|
        STDOUT.puts(entry)
      end
      0
    end
  end
end
