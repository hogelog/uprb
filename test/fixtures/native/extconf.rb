# frozen_string_literal: true

require "mkmf"
require "shellwords"

$srcs = ["uprb_fixture.c"]
if RUBY_PLATFORM.include?("darwin")
  companion = "libuprb_companion.dylib"
  flags = ["-dynamiclib", "-install_name", "@rpath/#{companion}"]
  $LDFLAGS << " -Wl,-rpath,@loader_path"
else
  companion = "libuprb_companion.so"
  flags = ["-shared", "-fPIC", "-Wl,-soname,#{companion}"]
  $LDFLAGS << " -Wl,-rpath,'$$ORIGIN'"
end
system(*Shellwords.split(RbConfig::CONFIG.fetch("CC")), *flags,
  "-o", companion, "companion.c") or abort "could not compile native companion"
$LOCAL_LIBS << " -L. -luprb_companion"
create_makefile("uprb_fixture")
