module Travis::Yaml
  module Nodes
    class Sequence < Node
      attr_reader :children
      alias_method :__getobj__, :children

      def self.type(identifier = nil)
        @type = Nodes[identifier] if identifier
        @type ||= superclass.respond_to?(:type) ? superclass.type : Scalar
      end

      def prepare
        @children = []
      end

      def visit_sequence(visitor, value)
        visitor.apply_sequence(self, value)
      end

      def visit_scalar(visitor, type, value, implicit = true)
        visit_child(visitor, value) if type != :null
      end

      def visit_mapping(visitor, value)
        visit_child(visitor, value)
      end

      def visit_child(visitor, value)
        child = self.class.type.new
        visitor.accept(child, value)
        @children << child
      end

      def nested_warnings(*prefix)
        @children.inject(super) do |list, value|
          list += value.nested_warnings(*prefix)
        end
      end

      def ==(other)
        other = other.children if other.is_a? Sequence
        if other.respond_to? :to_a and other.to_a.size == children.size
          children.zip(other.to_a).all? { |a, b| a == b }
        else
          false
        end
      end

      def empty?
        @children.empty?
      end

      def inspect
        @children.inspect
      end

      def verify
        @children.delete_if do |child|
          next unless child.errors?
          child.errors.each { |message| warning(message) }
          true
        end
        super
      end

      def deep_verify
        @children.each_value(&:deep_verify)
        super
      end
    end
  end
end