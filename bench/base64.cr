# bench/base64.cr
require "./bench_helper"

b      = Bytewire.new(1 << 16)
memory = IO::Memory.new(1 << 16)

{48, 3072, 1_048_576}.each do |size|
  data = Bytes.new(size) { |i| (i &* 31 &+ 7).to_u8! }
  Bench.group("base64 of #{size} bytes") do |job|
    job.report("Base64.strict_encode to String") do
      Bench.keep(Base64.strict_encode(data))
    end
    job.report("Base64.strict_encode to IO::Memory") do
      memory.clear
      Base64.strict_encode(data, memory)
      Bench.keep(memory)
    end
    job.report("base64") do
      b.reset
      b.base64(data)
      Bench.keep(b)
    end
  end
  encoded = Base64.strict_encode(data)
  Bench.group("base64 decoding of #{size} bytes") do |job|
    job.report("Base64.decode to Bytes") do
      Bench.sink &+= Base64.decode(encoded).size
    end
    job.report("decode64") do
      b.reset
      b.decode64(encoded)
      Bench.keep(b)
    end
  end
end
