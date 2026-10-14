# bench/text.cr
require "./bench_helper"

words  = Array.new(Bench::LARGE_BATCH) { |i| "word-#{i}" * (i % 4 + 1) }
chars  = Array.new(Bench::LARGE_BATCH) { |i| {'a', 'é', '漢', '🎉'}[i % 4] }
b      = Bytewire.new(1 << 18)
memory = IO::Memory.new(1 << 18)

Bench.group("short strings, #{Bench::LARGE_BATCH} per iteration") do |job|
  job.report("IO::Memory <<") do
    memory.clear
    words.each { |word| memory << word }
    Bench.keep(memory)
  end
  job.report("str") do
    b.reset
    words.each { |word| b.str(word) }
    Bench.keep(b)
  end
  job.report("bytes") do
    b.reset
    words.each { |word| b.bytes(word.to_slice) }
    Bench.keep(b)
  end
end

{Bench::BATCH, Bench::LARGE_BATCH}.each do |count|
  batch = chars.first(count)
  Bench.group("characters of 1 to 4 bytes, #{count} per iteration") do |job|
    job.report("IO::Memory <<") do
      memory.clear
      batch.each { |char| memory << char }
      Bench.keep(memory)
    end
    job.report("char") do
      b.reset
      batch.each { |char| b.char(char) }
      Bench.keep(b)
    end
    job.report("reserve + unsafe_char") do
      b.reset
      b.reserve(batch.size * 4)
      batch.each { |char| b.unsafe_char(char) }
      Bench.keep(b)
    end
  end
end

Bench.group("runs of 80 repeated characters, #{Bench::BATCH} per iteration") do |job|
  job.report("IO::Memory << ' ' * 80") do
    memory.clear
    Bench::BATCH.times { 80.times { memory << ' ' } }
    Bench.keep(memory)
  end
  job.report("repeat ascii") do
    b.reset
    Bench::BATCH.times { b.repeat(' ', 80) }
    Bench.keep(b)
  end
  job.report("IO::Memory << '─' * 80") do
    memory.clear
    Bench::BATCH.times { 80.times { memory << '─' } }
    Bench.keep(memory)
  end
  job.report("repeat multi-byte") do
    b.reset
    Bench::BATCH.times { b.repeat('─', 80) }
    Bench.keep(b)
  end
end

Bench.group("growth from 16 bytes to 1 MiB") do |job|
  chunk = ("x" * 64).to_slice
  job.report("IO::Memory") do
    io = IO::Memory.new(16)
    16_384.times { io.write(chunk) }
    Bench.keep(io)
  end
  job.report("Bytewire") do
    builder = Bytewire.new(16)
    16_384.times { builder.bytes(chunk) }
    Bench.keep(builder)
  end
end
