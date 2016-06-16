module GraphQL
  module Execution
    module DirectiveChecks
      SKIP = "skip"
      INCLUDE = "include"
      DEFER = "defer"

      module_function

      def defer?(ast_node)
        ast_node.directives.any? { |dir| dir.name == DEFER }
      end

      def skip?(ast_node, query)
        ast_node.directives.each do |ast_directive|
          if ast_directive.name == SKIP || ast_directive.name == INCLUDE
            directive = query.schema.directives[ast_directive.name]
            args = GraphQL::Query::LiteralInput.from_arguments(ast_directive.arguments, directive.arguments, query.variables)
            if !directive.include?(args)
              return true
            end
          end
        end
        false
      end
    end
  end
end
