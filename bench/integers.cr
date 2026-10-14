# bench/integers.cr
require "./bench_helper"

small  = Array.new(Bench::LARGE_BATCH) { |i| (i * 7) % 256 }
mixed  = Array.new(Bench::LARGE_BATCH) { |i| (i &* 2_654_435_761_u32.to_i32!) >> (i % 24) }
wide   = Array.new(Bench::LARGE_BATCH) { |i| (i.to_u64 + 1) &* 72_057_594_037_927_931_u64 }
b      = Bytewire.new(1 << 18)
memory = IO::Memory.new(1 << 18)

Bench.group("integers 0..255, #{Bench::LARGE_BATCH} per iteration") do |job|
  job.report("IO::Memory <<") do
    memory.clear
    small.each { |n| memory << n }
    Bench.keep(memory)
  end
  job.report("int") do
    b.reset
    small.each { |n| b.int(n) }
    Bench.keep(b)
  end
  job.report("int3") do
    b.reset
    small.each { |n| b.int3(n) }
    Bench.keep(b)
  end
  job.report("reserve + unsafe_int3") do
    b.reset
    b.reserve(small.size * 3)
    small.each { |n| b.unsafe_int3(n) }
    Bench.keep(b)
  end
end

Bench.group("signed 32-bit integers of mixed length, #{Bench::LARGE_BATCH} per iteration") do |job|
  job.report("IO::Memory <<") do
    memory.clear
    mixed.each { |n| memory << n }
    Bench.keep(memory)
  end
  job.report("int") do
    b.reset
    mixed.each { |n| b.int(n) }
    Bench.keep(b)
  end
end

Bench.group("unsigned 64-bit integers, #{Bench::LARGE_BATCH} per iteration") do |job|
  job.report("IO::Memory <<") do
    memory.clear
    wide.each { |n| memory << n }
    Bench.keep(memory)
  end
  job.report("int") do
    b.reset
    wide.each { |n| b.int(n) }
    Bench.keep(b)
  end
end

Bench.group("hexadecimal and zero-padded integers, #{Bench::LARGE_BATCH} per iteration") do |job|
  job.report("IO::Memory << to_s(16)") do
    memory.clear
    mixed.each { |n| n.to_u32!.to_s(memory, 16) }
    Bench.keep(memory)
  end
  job.report("hex") do
    b.reset
    mixed.each { |n| b.hex(n.to_u32!) }
    Bench.keep(b)
  end
  job.report("IO::Memory << to_s(precision: 3)") do
    memory.clear
    small.each { |n| n.to_s(memory, precision: 3) }
    Bench.keep(memory)
  end
  job.report("pad to 3") do
    b.reset
    small.each { |n| b.pad(n, 3) }
    Bench.keep(b)
  end
end

Bench.group("64-bit floats, #{Bench::LARGE_BATCH} per iteration") do |job|
  floats = Array.new(Bench::LARGE_BATCH) { |i| (i + 1) * 1.0625 / 7 }
  job.report("IO::Memory <<") do
    memory.clear
    floats.each { |n| memory << n }
    Bench.keep(memory)
  end
  job.report("put") do
    b.reset
    floats.each { |n| b.put(n) }
    Bench.keep(b)
  end
end
