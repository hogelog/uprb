# frozen_string_literal: true

require_relative "lib/rls/version"

Gem::Specification.new do |spec|
  spec.name = "rls"
  spec.version = Rls::VERSION
  spec.authors = ["hogelog"]
  spec.email = ["konbu.komuro@gmail.com"]

  spec.summary = "Example ls command gem"
  spec.description = "Example ls command gem"
  spec.homepage = "https://github.com/hogelog/uprb"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
end
