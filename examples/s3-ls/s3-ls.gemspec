# frozen_string_literal: true

require_relative "lib/s3/ls/version"

Gem::Specification.new do |spec|
  spec.name = "s3-ls"
  spec.version = S3::Ls::VERSION
  spec.authors = ["hogelog"]
  spec.email = ["konbu.komuro@gmail.com"]

  spec.summary = "Example S3 ls command gem"
  spec.description = "Example S3 ls command gem"
  spec.homepage = "https://github.com/hogelog/uprb"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
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

  spec.add_dependency "aws-sdk-s3", ">= 1.0"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
