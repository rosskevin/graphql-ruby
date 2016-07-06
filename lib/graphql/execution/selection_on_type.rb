module GraphQL
  module Execution
    # Flatten inline fragments
    # Merge in remote fragments
    module SelectionOnType
      module_function
      # Find selections on `ast_node` and reduce them to a single list.
      # - Check if fragments apply to `value`
      # - dedup any same-named fields
      # @return [Array<GraphQL::Language::Nodes::Field] flattened selections
      def flatten(exec_context, value, type_defn, ast_selection_nodes)
        merged_selections = flatten_selections(exec_context, value, type_defn, ast_selection_nodes)
        merged_selections.values
      end

      private

      module_function
      # Flatten selections on `ast_node`
      # @return [Hash<String, GraphQL::Language::Nodes::Field>] name-field pairs for flattened selections
      def flatten_selections(exec_context, value, type_defn, ast_selection_nodes)
        merged_selections = ast_selection_nodes.reduce({}) do |result, ast_selection|
          flattened_selections = flatten_selection(exec_context, value, type_defn, ast_selection)
          flattened_selections.each do |name, selection|
            result[name] = if result.key?(name) && selection.selections.any?
              # Create a new ast field node merging selections from each field.
              # Because of static validation, we can assume that name, alias,
              # arguments, and directives are exactly the same for fields 1 and 2.
              GraphQL::Language::Nodes::Field.new(
                name: selection.name,
                alias: selection.alias,
                arguments: selection.arguments,
                directives: selection.directives,
                selections: result[name].selections + selection.selections
              )
            else
              selection
            end
          end
          result
        end
        merged_selections
      end

      # Flatten individual selection, `ast_node`
      # @return [Hash<String, GraphQL::Language::Nodes::Field>] The mergeable result for this node
      def flatten_selection(exec_context, value, type_defn, ast_node)
        if GraphQL::Execution::DirectiveChecks.skip?(ast_node, exec_context.query)
          {}
        else
          case ast_node
          when GraphQL::Language::Nodes::Field
            result_name = ast_node.alias || ast_node.name
            { result_name => ast_node }
          when GraphQL::Language::Nodes::InlineFragment
            flatten_fragment(exec_context, value, type_defn, ast_node)
          when GraphQL::Language::Nodes::FragmentSpread
            ast_fragment_defn = exec_context.get_fragment(ast_node.name)
            flatten_fragment(exec_context, value, type_defn, ast_fragment_defn)
          end
        end
      end

      # Return a hash of selections from `ast_fragment` which apply to `type_defn`.
      # If no selections apply, it will be an empty hash.
      # @return [Hash<String, GraphQL::Language::Nodes::Field>] Selections to merge
      def flatten_fragment(exec_context, value, type_defn, ast_fragment)
        can_apply = if ast_fragment.type.nil?
          true
        else
          frag_type = exec_context.get_type(ast_fragment.type)
          GraphQL::Execution::Typecast.compatible?(value, type_defn, frag_type, exec_context.query.context)
        end

        if can_apply
          flatten_selections(exec_context, value, type_defn, ast_fragment.selections)
        else
          {}
        end
      end
    end
  end
end
