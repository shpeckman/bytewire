# src/bytewire/template.cr
class Bytewire
  SHAPES = {
    {types: {Int8, Int16, Int32, Int64, Int128},      first: "-0123456789", more: "0123456789", empty: false, open: false},
    {types: {UInt8, UInt16, UInt32, UInt64, UInt128}, first: "0123456789",  more: "0123456789", empty: false, open: false},
    {types: {Char},                                   first: "*",           more: "",           empty: false, open: false},
    {types: {String, Bytes},                          first: "*",           more: "",           empty: true,  open: true},
  }

  module Hex(T)
    BYTE_SHAPE = {first: "0123456789abcdefABCDEF", more: "0123456789abcdefABCDEF", value: 0, accepts: {UInt8, UInt16, UInt32, UInt64}}

    @[AlwaysInline]
    def self.bound(value : T, before : Bytes? = nil) : Int32
      16
    end

    @[AlwaysInline]
    def self.unsafe_write(builder : Bytewire, value : T) : Nil
      builder.unsafe_hex(value)
    end

    @[AlwaysInline]
    def self.read?(reader : Reader, before : Bytes? = nil) : T?
      reader.hex?(T)
    end
  end

  module Hex2
    BYTE_SHAPE = {first: "0123456789abcdefABCDEF", more: "", value: UInt8}

    @[AlwaysInline]
    def self.bound(value : UInt8, before : Bytes? = nil) : Int32
      2
    end

    @[AlwaysInline]
    def self.unsafe_write(builder : Bytewire, value : UInt8) : Nil
      builder.unsafe_hex2(value)
    end

    @[AlwaysInline]
    def self.read?(reader : Reader, before : Bytes? = nil) : UInt8?
      reader.hex2?
    end
  end

  module Padded(T, N)
    BYTE_SHAPE = {first: "-0123456789", more: "0123456789", value: 0, accepts: {Int8, Int16, Int32, Int64, UInt8, UInt16, UInt32, UInt64}}

    @[AlwaysInline]
    def self.bound(value : T, before : Bytes? = nil) : Int32
      ::Bytewire.bound_pad(value, N)
    end

    @[AlwaysInline]
    def self.unsafe_write(builder : Bytewire, value : T) : Nil
      builder.unsafe_pad(value, N)
    end

    def self.read?(reader : Reader, before : Bytes? = nil) : T?
      start = reader.pos
      value = reader.int?(T)
      return nil if value.nil?
      digits = reader.pos - start - (reader.data.unsafe_fetch(start) == 45_u8 ? 1 : 0)
      return value if digits >= N
      reader.pos = start
      nil
    end
  end

  module Base64(T)
    BYTE_SHAPE = {first: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=", more: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=", empty: true, value: 0, accepts: {String, Bytes}}

    @[AlwaysInline]
    def self.bound(value : T, before : Bytes? = nil) : Int32
      ::Bytewire.bound_base64(value)
    end

    @[AlwaysInline]
    def self.unsafe_write(builder : Bytewire, value : T) : Nil
      builder.unsafe_base64(value)
    end

    def self.read?(reader : Reader, before : Bytes? = nil) : T?
      start   = reader.pos
      encoded = reader.base64
      begin
        decoder = ::Bytewire.new(::Bytewire.bound_decode64(encoded))
        decoder.decode64(encoded)
        {% if T == String %}
          String.new(decoder.written)
        {% else %}
          decoder.written
        {% end %}
      rescue ArgumentError
        reader.pos = start
        nil
      end
    end
  end

  module List(T, S)
  end

  def self.bound(value : Bytes, before : Bytes?) : Int32
    if before
      clash = !Reader.index(value, before).nil?
      span  = before.size
      (1...span).each do |shift|
        break if shift > value.size
        clash ||= value[value.size - shift, shift] == before[0, shift] && before[shift, span - shift] == before[0, span - shift]
      end
      if clash
        raise ArgumentError.new("#{String.new(value).inspect} contains #{String.new(before).inspect}, the text that ends it")
      end
    end
    value.size
  end

  @[AlwaysInline]
  def self.bound(value : String, before : Bytes?) : Int32
    bound(value.to_slice, before)
  end

  def self.bound(items : Array(T), separator : Bytes, before : Bytes?) : Int32 forall T
    if items.size == 1 && items.unsafe_fetch(0).empty?
      raise ArgumentError.new("a list holding one empty item cannot be told apart from an empty list")
    end
    stops = {separator.unsafe_fetch(0), before.try(&.[0]?)}
    total = Math.max(items.size - 1, 0) * separator.size
    items.each do |item|
      data = item.to_slice
      stops.each do |stop|
        if stop && data.index(stop)
          raise ArgumentError.new("#{String.new(data).inspect} contains #{stop.unsafe_chr.inspect}, which begins the text that ends a list item")
        end
      end
      total += data.size
    end
    total
  end

  @[AlwaysInline]
  def <<(value : T) : self forall T
    {% unless T < ::Bytewire::Template %}
      {% raise "Bytewire#<< takes a value of a type declared with Bytewire.template, not #{T}" %}
    {% end %}
    reserve(T.bound(value))
    T.unsafe_write(self, value)
    self
  end

  module Template
    macro fields(*pieces)
      {% names = [] of StringLiteral %}
      {% types = [] of MacroId %}
      {% labels = [] of StringLiteral %}
      {% heads = [] of ArrayLiteral %}
      {% trails = [] of ArrayLiteral %}
      {% empties = [] of BoolLiteral %}
      {% opens = [] of BoolLiteral %}
      {% terms = [] of MacroId %}
      {% writes = [] of MacroId %}
      {% reads = [] of MacroId %}
      {% static = 0 %}
      {% for piece, index in pieces %}
        {% if piece.is_a?(StringLiteral) %}
          {% for char in piece.chars %}
            {% code = char.ord %}
            {% static += code < 0x80 ? 1 : (code < 0x800 ? 2 : (code < 0x10000 ? 3 : 4)) %}
          {% end %}
          {% labels << "" %}
          {% heads << ["=" + piece] %}
          {% trails << [] of StringLiteral %}
          {% empties << false %}
          {% opens << false %}
          {% writes << "builder.unsafe_str(#{piece})".id %}
          {% reads << "unless reader.match?(#{piece})\nreader.pos = __bbs\nreturn nil\nend\n".id %}
        {% else %}
          {% field = piece.var.stringify %}
          {% if names.includes?(field) %}
            {% piece.raise "template '#{@type.name}' declares the field '#{field.id}' twice" %}
          {% end %}
          {% resolved = piece.type.resolve %}
          {% wrap = "plain" %}
          {% base = resolved %}
          {% separator = nil %}
          {% if resolved.union? %}
            {% unless resolved.nilable? && resolved.union_types.size == 2 %}
              {% piece.raise "field '#{field.id}' has the union type #{resolved}, which has no encoding: the only union a field may have is 'Type?'" %}
            {% end %}
            {% wrap = "optional" %}
            {% base = resolved.union_types.find { |type| !type.nilable? } %}
          {% elsif resolved.name(generic_args: false).stringify == "Bytewire::List" %}
            {% wrap = "list" %}
            {% base = resolved.type_vars[0] %}
            {% separator = resolved.type_vars[1] %}
          {% end %}
          {% holder = base.type_vars.empty? ? base : parse_type("::#{base.name(generic_args: false)}").resolve %}
          {% shape = holder.has_constant?("BYTE_SHAPE") ? holder.constant("BYTE_SHAPE") : nil %}
          {% row = ::Bytewire::SHAPES.find { |entry| entry[:types].any? { |type| type.resolve == base } } %}
          {% unless shape || row %}
            {% piece.raise "field '#{field.id}' has type #{base}, which has no encoding: use an integer, Char, String, Bytes, a format such as Bytewire::Hex(UInt8), or another template" %}
          {% end %}
          {% source = shape || row %}
          {% empty = source[:empty] == true %}
          {% open = source[:open] == true %}
          {% head = [] of StringLiteral %}
          {% trail = [] of StringLiteral %}
          {% if source[:heads] %}
            {% for start in source[:heads] %}
              {% head << start %}
            {% end %}
            {% for start in source[:trails] %}
              {% trail << start %}
            {% end %}
          {% else %}
            {% head << (open && source[:first] == "*" ? "~" : ":" + source[:first]) %}
            {% trail << ":" + source[:more] unless source[:more].empty? %}
          {% end %}
          {% value = base %}
          {% if shape %}
            {% hint = shape[:value] %}
            {% value = hint.is_a?(NumberLiteral) ? base.type_vars[hint] : (hint ? hint.resolve : base) %}
            {% accepted = shape[:accepts] %}
            {% if accepted && !accepted.map(&.resolve).includes?(value) %}
              {% piece.raise "field '#{field.id}': #{base.name(generic_args: false)} cannot encode #{value}: it accepts #{accepted.splat}" %}
            {% end %}
          {% end %}
          {% strings = wrap == "list" && open && !shape %}
          {% delimiter = "nil" %}
          {% if open && (wrap != "list" || strings) %}
            {% following = pieces[index + 1] %}
            {% if following.is_a?(StringLiteral) %}
              {% delimiter = "#{following}.to_slice" %}
            {% elsif following.is_a?(NilLiteral) %}
              {% delimiter = "before" %}
            {% else %}
              {% piece.raise "field '#{field.id}' has no end: a #{base} is read up to the literal text that follows it, so it must be followed by literal text or be the last thing in the template" %}
            {% end %}
          {% end %}
          {% if shape %}
            {% bound = "::#{base}.bound(%value%, #{delimiter.id})" %}
            {% write = "::#{base}.unsafe_write(builder, %value%)" %}
            {% read = "::#{base}.read?(reader, #{delimiter.id})" %}
          {% else %}
            {% bound = open ? "::Bytewire.bound(%value%, #{delimiter.id})" : "::Bytewire.bound(%value%)" %}
            {% write = "builder.unsafe_put(%value%)" %}
            {% read = "reader.read?(::#{base}, #{delimiter.id})" %}
          {% end %}
          {% access = "value.#{field.id}" %}
          {% local = "__bbf_#{field.id}" %}
          {% if wrap == "plain" %}
            {% types << "::#{value}".id %}
            {% terms << bound.gsub(/%value%/, access).id %}
            {% writes << write.gsub(/%value%/, access).id %}
            {% reads << "#{local.id} = #{read.id}\nif #{local.id}.nil?\nreader.pos = __bbs\nreturn nil\nend\n".id %}
          {% elsif wrap == "optional" %}
            {% if empty %}
              {% piece.raise "field '#{field.id}' cannot be optional: a missing #{base} cannot be told apart from an empty one. Give it a template of its own that starts with literal text, and make that optional" %}
            {% end %}
            {% types << "(::#{value} | ::Nil)".id %}
            {% terms << "((__bbo = #{access.id}).nil? ? 0 : #{bound.gsub(/%value%/, "__bbo").id})".id %}
            {% writes << "unless (__bbo = #{access.id}).nil?\n#{write.gsub(/%value%/, "__bbo").id}\nend\n".id %}
            {% reads << "#{local.id} = #{read.id}\n".id %}
            {% empty = true %}
          {% else %}
            {% divider = separator.has_constant?("BYTE_SHAPE") ? separator.constant("BYTE_SHAPE") : nil %}
            {% unless divider && divider[:literal] == true %}
              {% piece.raise "the separator of field '#{field.id}' must be a template made only of literal text, not #{separator}" %}
            {% end %}
            {% mark = divider[:heads][0] %}
            {% split = "#{mark[1..-1]}.to_slice" %}
            {% types << "::Array(::#{value})".id %}
            {% writes << "#{access.id}.each_with_index do |__bbi, __bbn|\n::#{separator}.unsafe_write(builder, ::#{separator}.new) if __bbn > 0\n#{write.gsub(/%value%/, "__bbi").id}\nend\n".id %}
            {% if strings %}
              {% item = base.stringify == "String" ? "::String.new(__bbi)" : "__bbi" %}
              {% terms << "::Bytewire.bound(#{access.id}, #{split.id}, #{delimiter.id})".id %}
              {% reads << "#{local.id} = [] of ::#{value}\n__bbq = #{split.id}.unsafe_fetch(0)\n__bbt = #{delimiter.id}.try(&.[0]?)\nloop do\n__bbi = reader.take_while { |__bbc| __bbc != __bbq && __bbc != __bbt }\n#{local.id} << #{item.id}\nbreak unless ::#{separator}.read?(reader)\nend\n#{local.id}.clear if #{local.id}.size == 1 && #{local.id}.unsafe_fetch(0).empty?\n".id %}
              {% trail = [mark] %}
            {% else %}
              {% if empty %}
                {% piece.raise "field '#{field.id}' cannot be a list of #{base}: an empty item cannot be told apart from a missing one" %}
              {% end %}
              {% if open %}
                {% piece.raise "field '#{field.id}' cannot be a list of #{base}: a #{base} is read up to the literal text that follows it, and a list item has none. Give the item a template of its own that ends with literal text" %}
              {% end %}
              {% for mine in trail %}
                {% lead = mine.starts_with?("=") ? mine[1...2] : mine[1..-1] %}
                {% if lead == "*" || lead.chars.includes?(mark.chars[1]) %}
                  {% piece.raise "items of field '#{field.id}' run into their separator: #{separator} begins with a character that #{base} would take as its own" %}
                {% end %}
              {% end %}
              {% terms << "(#{access.id}.sum(0) { |__bbi| #{bound.gsub(/%value%/, "__bbi").id} } + ::Math.max(#{access.id}.size - 1, 0) * ::#{separator}.bound(::#{separator}.new))".id %}
              {% reads << "#{local.id} = [] of ::#{value}\nloop do\n__bbm = reader.pos\nbreak unless #{local.id}.empty? || ::#{separator}.read?(reader)\n__bbi = #{read.id}\nif __bbi.nil?\nreader.pos = __bbm\nbreak\nend\n#{local.id} << __bbi\nend\n".id %}
              {% trail << mark %}
              {% open = false %}
            {% end %}
            {% empty = true %}
          {% end %}
          {% names << field %}
          {% labels << field %}
          {% heads << head %}
          {% trails << trail %}
          {% empties << empty %}
          {% opens << open %}
        {% end %}
      {% end %}
      {% count = heads.size %}
      {% for index in 0...count %}
        {% pending = [] of StringLiteral %}
        {% for start in trails[index] %}
          {% pending << start %}
        {% end %}
        {% for start in heads[index] %}
          {% pending << start if empties[index] && start != "~" %}
        {% end %}
        {% reaching = true %}
        {% for later in 0...count %}
          {% if later > index && reaching %}
            {% for mine in pending %}
              {% for theirs in heads[later] %}
                {% clash = theirs == "~" %}
                {% if !clash && mine.starts_with?("=") && theirs.starts_with?("=") %}
                  {% others = theirs.chars %}
                  {% differ = false %}
                  {% for char, at in mine.chars %}
                    {% differ = true if at < others.size && char != others[at] %}
                  {% end %}
                  {% clash = !differ %}
                {% elsif !clash %}
                  {% left = mine.starts_with?("=") ? mine[1...2] : mine[1..-1] %}
                  {% right = theirs.starts_with?("=") ? theirs[1...2] : theirs[1..-1] %}
                  {% clash = left == "*" || right == "*" || left.chars.any? { |char| right.chars.includes?(char) } %}
                {% end %}
                {% if clash %}
                  {% raise "field '#{labels[index].id}' of template '#{@type.name}' cannot be told apart from what follows it: what comes next can begin the same way as text that reading would take as part of '#{labels[index].id}'. Put literal text that cannot begin that way between them" %}
                {% end %}
              {% end %}
            {% end %}
            {% reaching = empties[later] %}
          {% end %}
        {% end %}
      {% end %}
      {% front = [] of StringLiteral %}
      {% reaching = true %}
      {% for index in 0...count %}
        {% if reaching %}
          {% for start in heads[index] %}
            {% front << start %}
          {% end %}
          {% reaching = empties[index] %}
        {% end %}
      {% end %}
      {% hollow = reaching %}
      {% back = [] of StringLiteral %}
      {% reaching = true %}
      {% for offset in 0...count %}
        {% index = count - 1 - offset %}
        {% if reaching %}
          {% for start in trails[index] %}
            {% back << start %}
          {% end %}
          {% for start in heads[index] %}
            {% back << start if empties[index] && start != "~" %}
          {% end %}
          {% reaching = empties[index] %}
        {% end %}
      {% end %}
      BYTE_SHAPE = {heads: {{front.uniq}}, trails: {{back.empty? ? "[] of ::String".id : back.uniq}}, empty: {{hollow}}, open: {{opens.last}}, literal: {{names.empty?}}}

      {% for field, index in names %}
        getter {{field.id}} : {{types[index]}}
      {% end %}

      def initialize({% unless names.empty? %}*, {% for field, index in names %}@{{field.id}} : {{types[index]}}, {% end %}{% end %})
      end

      def self.bound(value : self, before : ::Bytes? = nil) : ::Int32
        {{static}}{% for term in terms %} + {{term}}{% end %}
      end

      def self.unsafe_write(builder : ::Bytewire, value : self) : ::Nil
        {% for line in writes %}
          {{line}}
        {% end %}
      end

      def self.read?(reader : ::Bytewire::Reader, before : ::Bytes? = nil) : self | ::Nil
        __bbs = reader.pos
        {% for line in reads %}
          {{line}}
        {% end %}
        new({% for field in names %}{{field.id}}: __bbf_{{field.id}}, {% end %})
      end

      def self.read(reader : ::Bytewire::Reader, before : ::Bytes? = nil) : self
        value = read?(reader, before)
        value.nil? ? raise(::Bytewire::Reader::Error.new({{@type.name.stringify}}, reader.pos)) : value
      end
    end
  end

  macro template(name, text)
    {% unless text.is_a?(StringInterpolation) || text.is_a?(StringLiteral) %}
      {% text.raise "Bytewire.template expects a string literal, not #{text.class_name.id}" %}
    {% end %}
    {% pieces = [] of ASTNode %}
    {% for piece in (text.is_a?(StringInterpolation) ? text.expressions : [text]) %}
      {% if piece.is_a?(StringLiteral) %}
        {% if !pieces.empty? && pieces.last.is_a?(StringLiteral) %}
          {% pieces[pieces.size - 1] = pieces.last + piece %}
        {% elsif !piece.empty? %}
          {% pieces << piece %}
        {% end %}
      {% else %}
        {% pieces << piece %}
      {% end %}
    {% end %}
    {% if pieces.empty? %}
      {% text.raise "template '#{name}' has no text" %}
    {% end %}
    {% for piece in pieces %}
      {% unless piece.is_a?(StringLiteral) || (piece.is_a?(TypeDeclaration) && piece.value.is_a?(Nop)) %}
        {% piece.raise "a template field must be written as 'name : Type', not #{piece.class_name.id}" %}
      {% end %}
    {% end %}
    struct {{name}}
      include ::Bytewire::Template
      fields({{pieces.splat}})
    end
  end
end
