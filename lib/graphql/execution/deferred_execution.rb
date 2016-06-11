module GraphQL
  module Execution
    # A query execution strategy that emits
    # `{ path: [...], value: ... }` patches as it
    # resolves the query.
    class DeferredExecution
      include GraphQL::Language
      def p_defers(as_text, defers)
        # p "#{as_text} #{defers.length}: #{defers.map(&:node).map(&:name)}"
      end

      def execute(ast_operation, root_type, query_object)
        collector = query_object.context[:collector]
        exec_context = Execution::Context.new(query_object, self)
        initial_defers = []
        initial_frame = Frame.new(
          node: ast_operation,
          value: query_object.root_value,
          type_defn: root_type,
          exec_context: exec_context,
          path: [],
        )
        resolve_or_defer_frame(initial_frame, initial_defers)

        if collector
          initial_patch = {"data" => initial_frame.result}

          error_idx = initial_frame.errors.length
          if initial_frame.errors.any?
            initial_patch["errors"] = initial_frame.errors.map(&:to_h)
          end

          collector.patch([], initial_patch)

          defers = initial_defers + initial_frame.defers
          while defers.any?
            p_defers("Starting", defers)
            next_defers = []
            defers.each do |deferred_frame|
              p_defers("Resolving", deferred_frame.defers)
              resolve_frame(deferred_frame)
              # No use patching for nil, that's there already
              if !deferred_frame.result.nil?
                collector.patch(["data"] + deferred_frame.path, deferred_frame.result)
              end
              deferred_frame.errors.each do |deferred_error|
                collector.patch(["errors", error_idx], deferred_error.to_h)
                error_idx += 1
              end
              p_defers("Pushing", deferred_frame.defers)
              next_defers.push(*deferred_frame.defers)
            end
            p_defers("Next", next_defers)
            if next_defers.length > 10
              raise "Bonkers"
            end
            defers = next_defers
          end
        end

        initial_frame.result
      end

      class Frame
        attr_reader :node, :value, :type_defn, :exec_context, :path, :defers, :errors
        attr_accessor :result
        def initialize(node:, value:, type_defn:, exec_context:, path:)
          @node = node
          @value = value
          @type_defn = type_defn
          @exec_context = exec_context
          @path = path
          @result = :__undefined__
          @defers = []
          @errors = []
        end

        def spawn_child(child_options)
          own_options = {
            node: @node,
            value: @value,
            type_defn: @type_defn,
            exec_context: @exec_context,
            path: @path,
          }
          init_options = own_options.merge(child_options)
          self.class.new(init_options)
        end
      end

      private

      def resolve_or_defer_frame(frame, defers)
        if frame.node.directives.any? { |dir| dir.name == "defer" }
          defers << frame
          frame.result = nil
        else
          resolve_frame(frame)
        end
      end

      # Write the result into this frame
      def resolve_frame(frame)
        ast_node = frame.node
        case ast_node
        when Nodes::OperationDefinition
          resolve_selections(ast_node.selections, frame)
        when Nodes::Field
          type_defn = frame.type_defn
          # Use Context because it provides dynamic fields too (like __typename)
          field_defn = frame.exec_context.get_field(type_defn, ast_node.name)

          field_result = resolve_field_frame(field_defn, frame)
          return_type_defn = field_defn.type

          if field_result.is_a?(GraphQL::ExecutionError)
            frame.errors << field_result
            frame.result = nil
          else
            resolve_value(
              type_defn: return_type_defn,
              value: field_result,
              frame: frame,
            )
          end
        else
          raise("No defined resolution for #{ast_node.class.name} (#{ast_node})")
        end
      end

      def resolve_selections(selections, outer_frame)
        resolved_selections = selections.each_with_object({}) do |ast_selection, memo|
          selection_key = path_step(ast_selection)

          inner_frame = outer_frame.spawn_child(
            node: ast_selection,
            path: outer_frame.path + [selection_key],
          )

          resolve_or_defer_frame(inner_frame, outer_frame.defers)
          outer_frame.errors.push(*inner_frame.errors)
          outer_frame.defers.push(*inner_frame.defers)
          memo[selection_key] = inner_frame.result
        end
        outer_frame.result = resolved_selections
      end

      def path_step(ast_node)
        case ast_node
        when Nodes::Field
          ast_node.alias || ast_node.name
        else
          ast_node.name
        end
      end

      def resolve_field_frame(field_defn, frame)
        ast_node = frame.node
        type_defn = frame.type_defn
        value = frame.value
        query = frame.exec_context.query

        # Build arguments according to query-string literals, default values, and query variables
        arguments = GraphQL::Query::LiteralInput.from_arguments(
          ast_node.arguments,
          field_defn.arguments,
          query.variables
        )

        # This is the last call in the middleware chain; it actually calls the user's resolve proc
        field_resolve_middleware_proc = -> (_parent_type, parent_object, field_definition, field_args, context, _next) {
          context.ast_node = ast_node
          value = field_definition.resolve(parent_object, field_args, context)
          context.ast_node = nil
          value
        }

        # Send arguments through the middleware stack,
        # ending with the field resolve call
        steps = query.schema.middleware + [field_resolve_middleware_proc]
        chain = GraphQL::Schema::MiddlewareChain.new(
          steps: steps,
          arguments: [type_defn, value, field_defn, arguments, query.context]
        )

        begin
          chain.call
        rescue GraphQL::ExecutionError => err
          err
        end
      end

      def resolve_value(type_defn:, value:, frame:)
        if value.nil? || value.is_a?(GraphQL::ExecutionError)
          if type_defn.kind.non_null?
            raise GraphQL::InvalidNullError.new(frame.node.name, value)
          else
            frame.result = nil
          end
        else
          case type_defn.kind
          when GraphQL::TypeKinds::SCALAR, GraphQL::TypeKinds::ENUM
            frame.result = type_defn.coerce_result(value)
          when GraphQL::TypeKinds::NON_NULL
            wrapped_type = type_defn.of_type
            resolve_value(type_defn: wrapped_type, value: value, frame: frame)
          when GraphQL::TypeKinds::LIST
            wrapped_type = type_defn.of_type
            resolved_values = value.each_with_index.map do |item, idx|
              inner_frame = frame.spawn_child({
                path: frame.path + [idx]
              })
              resolve_value(type_defn: wrapped_type, value: item, frame: inner_frame)
              frame.errors.push(*inner_frame.errors)
              frame.defers.push(*inner_frame.defers)
              inner_frame.result
            end
            frame.result = resolved_values
          when GraphQL::TypeKinds::INTERFACE, GraphQL::TypeKinds::UNION
            resolved_type = type_defn.resolve_type(value, exec_context)

            if !resolved_type.is_a?(GraphQL::ObjectType)
              raise GraphQL::ObjectType::UnresolvedTypeError.new(type_defn, value)
            else
              resolve_value(value: value, type_defn: resolved_type, frame: frame)
            end
          when GraphQL::TypeKinds::OBJECT
            inner_frame = frame.spawn_child(
              value: value,
              type_defn: type_defn,
            )
            resolve_selections(frame.node.selections, inner_frame)
            frame.errors.push(*inner_frame.errors)
            frame.defers.push(*inner_frame.defers)
            frame.result = inner_frame.result
          else
            raise("No ResolveValue for kind: #{type_defn.kind.name} (#{type_defn})")
          end
        end
      end
    end
  end
end
