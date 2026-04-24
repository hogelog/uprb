# frozen_string_literal: true

require "fileutils"
require "optparse"
require_relative "../uprb"

module Uprb
  class CLI
    USAGE = <<~USAGE.chomp
    Usage:
      uprb pack <src.rb> <dest>
      uprb gem install <gem> [--path DIR]
      uprb gem pack <gem> [--path DIR]
    USAGE

    def self.start(argv = ARGV)
      new(argv).run
    end

    def initialize(argv)
      @argv = argv.dup
    end

    def run
      command = @argv.shift

      case command
      when "pack"
        pack_command
      when "gem"
        gem_command
      when "--version", "-v"
        $stdout.puts(Uprb::VERSION)
      when "--help", "-h", nil
        $stdout.puts(USAGE)
      else
        $stderr.puts(USAGE)
      end
    rescue Uprb::Error => e
      $stderr.puts("uprb: #{e.message}")
      exit 1
    rescue StandardError => e
      $stderr.puts("uprb: #{e.class}: #{e.message}")
      exit 1
    end

    private

    def pack_command
      options, args = parse_pack_options(@argv)
      src = args.shift or raise Uprb::Error, "missing <src.rb>"
      dest = args.shift or raise Uprb::Error, "missing <dist>"

      src_path = File.expand_path(src)
      dest_path = File.expand_path(dest)

      raise Uprb::Error, "source not found: #{src}" unless File.file?(src_path)

      FileUtils.mkdir_p(File.dirname(dest_path))
      return unless confirm_overwrite(dest_path, options)

      Uprb::RequireReplacer.pack(src_path, dest_path:, requires: options[:requires], dynamic: options[:dynamic])

      $stdout.puts("Packed #{dest_path}")
    end

    def gem_command
      subcommand = @argv.shift

      case subcommand
      when "install"
        options, args = parse_pack_options(@argv)
        gem_name = args.shift or raise Uprb::Error, "missing <gem>"
        install_gem(gem_name)
        pack_gem_executables(gem_name, options)
      when "pack"
        options, args = parse_pack_options(@argv)
        gem_name = args.shift or raise Uprb::Error, "missing <gem>"
        pack_gem_executables(gem_name, options)
      else
        $stdout.puts(USAGE)
      end
    end

    def parse_pack_options(argv)
      options = {
        path: nil,
        force: false,
        requires: [],
        dynamic: false,
      }
      parser = OptionParser.new
      parser.on("--path DIR") do |dir|
        options[:path] = dir
      end
      parser.on("-f", "--force", "overwrite existing destination without prompting") do
        options[:force] = true
      end
      parser.on("-r", "--require LIB", "pre-require LIB at pack time and at runtime (repeatable)") do |lib|
        options[:requires] << lib
      end
      parser.on("--with-rubygems", "shortcut for --require rubygems") do
        options[:requires] << "rubygems"
      end
      parser.on("--dynamic", "execute the entry script at pack time to observe runtime-only requires") do
        options[:dynamic] = true
      end
      args = parser.parse(argv)

      [options, args]
    rescue OptionParser::ParseError => e
      raise Uprb::Error, e.message
    end

    def confirm_overwrite(dest_path, options)
      return true if options[:force]
      return true unless File.exist?(dest_path)

      unless $stdin.tty?
        raise Uprb::Error, "destination already exists: #{dest_path} (pass --force to overwrite)"
      end

      $stderr.print("uprb: #{dest_path} already exists. overwrite? [y/N]: ")
      answer = $stdin.gets
      return true if answer && answer.strip.match?(/\A(y|yes)\z/i)

      $stdout.puts("skipped #{dest_path}")
      false
    end

    def install_gem(gem_name)
      command = [RbConfig.ruby, "-S", "gem", "install", gem_name]
      system(*command) or raise Uprb::Error, "gem install failed: #{gem_name}"
    end

    def pack_gem_executables(gem_name, options)
      spec = Gem::Specification.find_by_name(gem_name)
      executables = spec.executables
      raise Uprb::Error, "no executables for gem: #{gem_name}" if executables.empty?
      bindir = spec.bindir

      dest_dir = options[:path] ? File.expand_path(options[:path]) : Gem.bindir
      FileUtils.mkdir_p(dest_dir)

      executables.each do |exe|
        source_path = File.join(spec.full_gem_path, bindir, exe)
        raise Uprb::Error, "executable not found: #{source_path}" unless File.file?(source_path)

        dest_path = File.join(dest_dir, exe)

        next unless confirm_overwrite(dest_path, options)

        Uprb::RequireReplacer.pack(source_path, dest_path:, requires: options[:requires], dynamic: options[:dynamic])
        $stdout.puts("Packed #{dest_path}")
      end
    rescue Gem::LoadError => e
      raise Uprb::Error, e.message
    end
  end
end
