require 'psych'
require 'delegate'

module Travis::Yaml
  module Parser
    class Psych
      class SetNode < DelegateClass(::Psych::Nodes::Mapping)
        def children
          super.select.with_index { |_,i| i.even? }
        end
      end

      class ScalarSequence < DelegateClass(::Psych::Nodes::Mapping)
        def children
          [__getobj__]
        end
      end

      MAP       = /\A(?:tag:yaml\.org,2002:|!!?)map\z/
      OMAP      = /\A(?:tag:yaml\.org,2002:|!!?)omap\z/
      PAIRS     = /\A(?:tag:yaml\.org,2002:|!!?)pairs\z/
      SET       = /\A(?:tag:yaml\.org,2002:|!!?)set\z/
      SEQ       = /\A(?:tag:yaml\.org,2002:|!!?)seq\z/
      BINARY    = /\A(?:tag:yaml\.org,2002:|!!?)binary\z/
      BOOL      = /\A(?:tag:yaml\.org,2002:|!!?)bool\z/
      FLOAT     = /\A(?:tag:yaml\.org,2002:|!!?)float\z/
      INT       = /\A(?:tag:yaml\.org,2002:|!!?)int\z/
      MERGE     = /\A(?:tag:yaml\.org,2002:|!!?)merge\z/
      NULL      = /\A(?:tag:yaml\.org,2002:|!!?)null\z/
      STR       = /\A(?:tag:yaml\.org,2002:|!!?)str\z/
      TIMESTAMP = /\A(?:tag:yaml\.org,2002:|!!?)timestamp\z/
      VALUE     = /\A(?:tag:yaml\.org,2002:|!!?)value\z/
      YAML      = /\A(?:tag:yaml\.org,2002:|!!?)yaml\z/
      SECURE    = /\A!(?:encrypted|secure|decrypted)\z/

      # copied from YAML spec
      TRUE      = /\A(?:y|Y|yes|Yes|YES|true|True|TRUE|on|On|ON)\z/
      FALSE     = /\A(?:n|N|no|No|NO|false|False|FALSE|off|Off|OFF)\z/
      FORMATS   = {
        '!bool'      => Regexp.union(TRUE, FALSE),
        '!float'     => ::Psych::ScalarScanner::FLOAT,
        '!null'      => /\A(:?~|null|Null|NULL|)\z/,
        '!timestamp' => ::Psych::ScalarScanner::TIME,
        '!int'       => ::Psych::ScalarScanner::INTEGER
      }

      def self.parses?(value)
        return true if value.is_a?(::Psych::Nodes::Node)
        return true if value.is_a?(String) or value.is_a?(IO)
        return true if defined?(StringIO) and value.is_a?(StringIO)
        value.respond_to?(:to_str) or value.respond_to?(:to_io)
      end

      def self.parse(value)
        new(value).parse
      end

      def initialize(value)
        value    = value.to_str if value.respond_to? :to_str
        value    = value.to_io  if value.respond_to? :to_io
        @value   = value
        @scanner = ::Psych::ScalarScanner.new
      end

      def parse(root = nil)
        root   ||= Travis::Yaml::Nodes::Root.new
        parsed   = @value if @value.is_a? ::Psych::Nodes::Node
        parsed ||= ::Psych.parse(@value)
        accept(root, parsed)
        root
      end

      def accept(node, value)
        case value
        when ::Psych::Nodes::Scalar   then accept_scalar   node, value
        when ::Psych::Nodes::Mapping  then accept_mapping  node, value
        when ::Psych::Nodes::Sequence then accept_sequence node, value
        when ::Psych::Nodes::Alias    then accept_alias    node, value
        when ::Psych::Nodes::Document then accept          node, value.root
        when ::Psych::Nodes::Stream   then accept_sequence node, value
        else node.visit_unexpected(self, value) if value
        end
        node.verify
      end

      def accept_sequence(node, value)
        case value.tag
        when SET, SEQ
          node.visit_sequence self, value
        when nil
          value = ScalarSequence.new(value) unless value.is_a? ::Psych::Nodes::Sequence
          node.visit_sequence self, value
        else
          node.visit_sequence self, ScalarSequence.new(value)
        end
      end

      def accept_mapping(node, value)
        case value.tag
        when MAP, OMAP, PAIRS then node.visit_mapping  self, value
        when SET              then node.visit_sequence self, SetNode.new(value)
        when SEQ              then node.visit_sequence self, value
        when nil
          if value.children.size == 2 and value.children.first.value == 'secure'
            node.visit_scalar(self, :secure, value.children.last)
          else
            node.visit_mapping(self, value)
          end
        else
          node.visit_unexpected self, value, "unexpected tag %p for mapping" % value.tag
        end
      end

      def accept_scalar(node, value)
        case tag = scalar_tag(value)
        when BINARY    then node.visit_scalar self, :binary, value, value.tag.nil?
        when BOOL      then node.visit_scalar self, :bool,   value, value.tag.nil?
        when FLOAT     then node.visit_scalar self, :float,  value, value.tag.nil?
        when INT       then node.visit_scalar self, :int,    value, value.tag.nil?
        when NULL      then node.visit_scalar self, :null,   value, value.tag.nil?
        when STR       then node.visit_scalar self, :str,    value, value.tag.nil?
        when TIMESTAMP then node.visit_scalar self, :time,   value, value.tag.nil?
        when SECURE    then node.visit_scalar self, :secure, value, value.tag.nil?
        when NULL      then node.visit_scalar self, :null,   value, value.tag.nil?
        else node.visit_unexpected self, value, "unexpected tag %p for scalar %p" % [tag, value]
        end
      end

      def scalar_tag(value)
        return value.tag if value.tag
        return '!str' if value.quoted
        FORMATS.each do |tag, format|
          return tag if value.value =~ format
        end
        '!str'
      end

      def cast(type, value)
        case type
        when :str    then value.value
        when :binary then value.value.unpack('m').first
        when :bool   then value.value !~ FALSE
        when :float  then Float   @scanner.tokenize(value.value)
        when :int    then Integer @scanner.tokenize(value.value)
        when :time   then @scanner.parse_time(value.value)
        when :secure then SecureString.new(value.value, value.tag != '!decrypted')
        when :null   then nil
        else raise ArgumentError, 'unknown scalar type %p' % type
        end
      end

      def apply_mapping(node, value)
        keys, values = value.children.group_by.with_index { |_,i| i.even? }.values_at(true, false)
        keys.zip(values) { |key, value| node.visit_pair(self, key, value) } if keys and values
      end

      def apply_sequence(node, value)
        value.children.each { |child| node.visit_child(self, child) }
      end

      def generate_key(node, value)
        unless value.respond_to? :value and (value.tag.nil? || value.tag == STR)
          node.visit_unexpected(self, value, "expected string as key")
        end

        value = value.value.to_s
        value.start_with?(?:) ? value[1..-1] : value
      end
    end
  end
end