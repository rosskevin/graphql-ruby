module GraphQL
  module Execution
    class Context
      attr_reader :query, :schema, :strategy

      def initialize(query, strategy)
        @query = query
        @schema = query.schema
        @strategy = strategy
      end

      def get_type(type)
        @schema.types[type]
      end

      def get_fragment(name)
        @query.fragments[name]
      end

      def get_field(type, name)
        @schema.get_field(type, name) || raise("No type named '#{name}' found for #{type}")
      end

      def add_error(err)
        @query.context.errors << err
      end
    end
  end
end
