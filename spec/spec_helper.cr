# spec/spec_helper.cr
require "spec"
require "base64"
require "../src/bytewire"

COMPILER = ENV["CRYSTAL"]? || "crystal"

def text(builder : Bytewire) : String
  String.new(builder.written)
end

def compile_output(source : String) : String
  path = File.join(__DIR__, "compile_probe_#{Random::Secure.hex(6)}.cr")
  File.write(path, %(require "../src/bytewire"\n#{source}\n))
  output = IO::Memory.new
  status = Process.run(COMPILER, ["build", "--no-codegen", "--no-color", path], output: output, error: output)
  status.success? ? "" : output.to_s
ensure
  File.delete?(path) if path
end
