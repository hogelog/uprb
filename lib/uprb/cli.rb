# frozen_string_literal: true

require "fileutils"
require "optparse"
require_relative "../uprb"

module Uprb
  class CLI
    USAGE = <<~USAGE.chomp
    Usage:
      uprb pack <src.rb> <dest> [--skip-iseq-cache] [--enable-rubygems]
      uprb gem install <gem> [--skip-iseq-cache] [--enable-rubygems] [--path DIR]
      uprb gem pack <gem> [--skip-iseq-cache] [--enable-rubygems] [--path DIR]
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
      if options[:skip_iseq_cache]
        Uprb::RequireReplacer.pack(
          src_path,
          dest_path:,
          enable_rubygems: options[:enable_rubygems]
        )
      else
        Uprb::RequireReplacer.pack_iseq(
          src_path,
          dest_path:,
          enable_rubygems: options[:enable_rubygems]
        )
      end

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
        skip_iseq_cache: false,
        enable_rubygems: false,
        path: nil,
      }
      parser = OptionParser.new
      parser.on("--skip-iseq-cache") { options[:skip_iseq_cache] = true }
      parser.on("--enable-rubygems") do
        options[:enable_rubygems] = true
      end
      parser.on("--path DIR") do |dir|
        options[:path] = dir
      end
      args = parser.parse(argv)

      [options, args]
    rescue OptionParser::ParseError => e
      raise Uprb::Error, e.message
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

        if options[:skip_iseq_cache]
          Uprb::RequireReplacer.pack(
            source_path,
            dest_path:,
            enable_rubygems: options[:enable_rubygems]
          )
        else
          Uprb::RequireReplacer.pack_iseq(
            source_path,
            dest_path:,
            enable_rubygems: options[:enable_rubygems]
          )
        end
        $stdout.puts("Packed #{dest_path}")
      end
    rescue Gem::LoadError => e
      raise Uprb::Error, e.message
    end
  end
end
