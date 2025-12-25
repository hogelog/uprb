# frozen_string_literal: true

require "fileutils"
require_relative "../uprb"

module Uprb
  class CLI
    USAGE = <<~USAGE.chomp
    Usage:
      uprb pack <src.rb> <dest> [--skip-iseq-cache]
      uprb gem install <gem> [--skip-iseq-cache]
      uprb gem pack <gem> [--skip-iseq-cache]
    USAGE

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
      when "gem"
        gem_command
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
      skip_iseq = parse_pack_options

      src_path = File.expand_path(src)
      dest_path = File.expand_path(dest)

      raise Uprb::Error, "source not found: #{src}" unless File.file?(src_path)

      FileUtils.mkdir_p(File.dirname(dest_path))
      if skip_iseq
        Uprb::RequireReplacer.pack(src_path, dest_path)
      else
        Uprb::RequireReplacer.pack_iseq(src_path, dest_path)
      end

      @stdout.puts("Packed #{dest_path}")
      0
    end

    def gem_command
      subcommand = @argv.shift

      case subcommand
      when "install"
        gem_name = @argv.shift or raise Uprb::Error, "missing <gem>"
        skip_iseq = parse_pack_options
        install_gem(gem_name)
        pack_gem_executables(gem_name, skip_iseq)
      when "pack"
        gem_name = @argv.shift or raise Uprb::Error, "missing <gem>"
        skip_iseq = parse_pack_options
        pack_gem_executables(gem_name, skip_iseq)
      else
        remaining = [subcommand, *@argv].compact.join(" ")
        raise Uprb::Error, "unexpected arguments: #{remaining}"
      end
      0
    end

    def parse_pack_options
      skip_iseq = false

      while @argv.any?
        arg = @argv.shift
        case arg
        when "--skip-iseq-cache"
          skip_iseq = true
        else
          remaining = [arg, *@argv].join(" ")
          raise Uprb::Error, "unexpected arguments: #{remaining}"
        end
      end

      skip_iseq
    end

    def install_gem(gem_name)
      require "rubygems/dependency_installer"

      installer = Gem::DependencyInstaller.new(document: [])
      installer.install(gem_name)
      Gem::Specification.reset
    rescue Gem::InstallError, Gem::Exception => e
      raise Uprb::Error, e.message
    end

    def pack_gem_executables(gem_name, skip_iseq)
      spec = Gem::Specification.find_by_name(gem_name)
      executables = spec.executables
      raise Uprb::Error, "no executables for gem: #{gem_name}" if executables.empty?
      bindir = spec.bindir

      executables.each do |exe|
        source_path = File.join(spec.full_gem_path, bindir, exe)
        raise Uprb::Error, "executable not found: #{source_path}" unless File.file?(source_path)

        dest_path = File.join(Gem.bindir, exe)

        if skip_iseq
          Uprb::RequireReplacer.pack(source_path, dest_path)
        else
          Uprb::RequireReplacer.pack_iseq(source_path, dest_path)
        end
        @stdout.puts("Packed #{dest_path}")
      end
    rescue Gem::LoadError => e
      raise Uprb::Error, e.message
    end
  end
end
