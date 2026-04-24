#!/usr/bin/env ruby
v = Gem::Version.new("1.2.3")
p = Gem::Platform.local
r = Gem::Requirement.new(">= 1.0")
puts "ok" if v && p && r.satisfied_by?(v)
