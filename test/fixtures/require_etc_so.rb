require "etc.so"
puts "Etc loaded: #{Etc.respond_to?(:passwd)}"
