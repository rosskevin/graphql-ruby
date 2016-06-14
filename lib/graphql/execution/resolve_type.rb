module GraphQL
  module Execution
    module ResolveType
      def self.resolve(value, inner_type, outer_type, query_ctx)
        if inner_type.nil?
          nil
        elsif outer_type.kind.union?
          outer_type.resolve_type(value)
        elsif inner_type.kind.union? && inner_type.include?(outer_type)
          outer_type
        elsif inner_type.kind.interface?
          inner_type.resolve_type(value, query_ctx)
        elsif inner_type == outer_type
          outer_type
        else
          nil
        end
      end
    end
  end
end
