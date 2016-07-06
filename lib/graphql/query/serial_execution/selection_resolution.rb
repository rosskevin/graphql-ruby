module GraphQL
  class Query
    class SerialExecution
      class SelectionResolution
        attr_reader :target, :type, :selections, :execution_context

        def initialize(target, type, selections, execution_context)
          @target = target
          @type = type
          @selections = selections
          @execution_context = execution_context
        end

        def result
          flattened_selections = GraphQL::Execution::SelectionOnType.flatten(execution_context, target, type, selections)
          flattened_selections.reduce({}) do |result, ast_node|
            field_result = if GraphQL::Execution::DirectiveChecks.skip?(ast_node, execution_context.query)
              {}
            else
              execution_context.strategy.field_resolution.new(
                ast_node,
                type,
                target,
                execution_context
              ).result
            end

            result.merge(field_result)
          end
        rescue GraphQL::InvalidNullError => err
          err.parent_error? || execution_context.add_error(err)
          nil
        end

        private

        def resolve_field(ast_node)

        end
      end
    end
  end
end
