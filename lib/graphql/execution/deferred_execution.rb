module GraphQL
  module Execution
    # A query execution strategy that emits
    # `{ path: [...], value: ... }` patches as it
    # resolves the query.
    #
    # TODO: how to handle if a selection set defers one member,
    # but a later member gets InvalidNullError?
    class DeferredExecution
      include GraphQL::Language

      def execute(ast_operation, root_type, query_object)
        collector = query_object.context[:collector]

        scope = ExecScope.new(query_object)
        initial_thread = ExecThread.new
        initial_frame = ExecFrame.new(
          node: ast_operation,
          value: query_object.root_value,
          type: root_type,
          path: []
        )

        initial_result = resolve_or_defer_frame(scope, initial_thread, initial_frame)

        if collector
          initial_patch = {"data" => initial_result}

          initial_errors = initial_thread.errors + query_object.context.errors
          error_idx = initial_errors.length

          if initial_errors.any?
            initial_patch["errors"] = initial_errors.map(&:to_h)
          end

          collector.patch([], initial_patch)

          defers = initial_thread.defers
          while defers.any?
            next_defers = []
            defers.each do |deferred_frame|
              deferred_thread = ExecThread.new
              deferred_result = resolve_frame(scope, deferred_thread, deferred_frame)
              # No use patching for nil, that's there already
              if !deferred_result.nil?
                collector.patch(["data"] + deferred_frame.path, deferred_result)
              end
              deferred_thread.errors.each do |deferred_error|
                collector.patch(["errors", error_idx], deferred_error.to_h)
                error_idx += 1
              end
              next_defers.push(*deferred_thread.defers)
            end
            defers = next_defers
          end
        else
          query_object.context.errors.push(*initial_thread.errors)
        end

        initial_result
      end

      # Global, window-like object for a query
      class ExecScope
        attr_reader :query, :schema

        def initialize(query)
          @query = query
          @schema = query.schema
        end

        def get_type(type)
          @schema.types[type]
        end

        def get_fragment(name)
          @query.fragments[name]
        end

        def get_field(type, name)
          @schema.get_field(type, name) || raise("No field named '#{name}' found for #{type}")
        end
      end

      # One serial stream of execution
      class ExecThread
        attr_reader :errors, :defers
        def initialize
          @errors = []
          @defers = []
        end
      end

      # One step of execution
      class ExecFrame
        attr_reader :node, :path, :type, :value
        def initialize(node:, path:, type:, value:)
          @node = node
          @path = path
          @type = type
          @value = value
        end
      end

      private

      # If this `frame` is marked as defer, add it to `defers`
      # Otherwise, resolve it.
      def resolve_or_defer_frame(scope, thread, frame)
        if frame.node.directives.any? { |dir| dir.name == "defer" }
          thread.defers << frame
          nil
        else
          resolve_frame(scope, thread, frame)
        end
      end

      # Determine this frame's result and write it into `#result`.
      # Anything marked as `@defer` will be deferred.
      def resolve_frame(scope, thread, frame)
        ast_node = frame.node
        case ast_node
        when Nodes::OperationDefinition
          resolve_selections(scope, thread, frame)
        when Nodes::Field
          type_defn = frame.type
          # Use scope because it provides dynamic fields too (like __typename)
          field_defn = scope.get_field(type_defn, ast_node.name)

          field_result = resolve_field_frame(scope, thread, frame, field_defn)
          return_type_defn = field_defn.type

            resolve_value(
              scope,
              thread,
              frame,
              field_result,
              return_type_defn,
            )
        else
          raise("No defined resolution for #{ast_node.class.name} (#{ast_node})")
        end
      end

      def resolve_selections(scope, thread, outer_frame)
        merged_selections = GraphQL::Execution::SelectionOnType.flatten(
          scope,
          outer_frame.value,
          outer_frame.type,
          outer_frame.node,
        )

        resolved_selections = merged_selections.each_with_object({}) do |ast_selection, memo|
          selection_key = path_step(ast_selection)

          inner_frame = ExecFrame.new(
            node: ast_selection,
            path: outer_frame.path + [selection_key],
            type: outer_frame.type,
            value: outer_frame.value,
          )

          inner_result = resolve_or_defer_frame(scope, thread, inner_frame)
          memo[selection_key] = inner_result
        end
        resolved_selections
      rescue GraphQL::InvalidNullError => err
        err.parent_error? || thread.errors << err
        nil
      end

      def path_step(ast_node)
        case ast_node
        when Nodes::Field
          ast_node.alias || ast_node.name
        else
          ast_node.name
        end
      end

      def resolve_field_frame(scope, thread, frame, field_defn)
        ast_node = frame.node
        type_defn = frame.type
        value = frame.value
        query = scope.query

        # Build arguments according to query-string literals, default values, and query variables
        arguments = GraphQL::Query::LiteralInput.from_arguments(
          ast_node.arguments,
          field_defn.arguments,
          query.variables
        )

        # This is the last call in the middleware chain; it actually calls the user's resolve proc
        field_resolve_middleware_proc = -> (_parent_type, parent_object, field_definition, field_args, query_ctx, _next) {
          query_ctx.ast_node = ast_node
          value = field_definition.resolve(parent_object, field_args, query_ctx)
          query_ctx.ast_node = nil
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
          resolve_fn_value = chain.call
        rescue GraphQL::ExecutionError => err
          resolve_fn_value = err
        end

        if resolve_fn_value.is_a?(GraphQL::ExecutionError)
          thread.errors << resolve_fn_value
          resolve_fn_value.ast_node = ast_node
        end

        resolve_fn_value
      end

      def resolve_value(scope, thread, frame, value, type_defn)
        if value.nil? || value.is_a?(GraphQL::ExecutionError)
          if type_defn.kind.non_null?
            raise GraphQL::InvalidNullError.new(frame.node.name, value)
          else
            nil
          end
        else
          case type_defn.kind
          when GraphQL::TypeKinds::SCALAR, GraphQL::TypeKinds::ENUM
            type_defn.coerce_result(value)
          when GraphQL::TypeKinds::NON_NULL
            wrapped_type = type_defn.of_type
            resolve_value(scope, thread, frame, value, wrapped_type)
          when GraphQL::TypeKinds::LIST
            wrapped_type = type_defn.of_type
            resolved_values = value.each_with_index.map do |item, idx|
              inner_frame = ExecFrame.new({
                node: frame.node,
                path: frame.path + [idx],
                type: wrapped_type,
                value: item,
              })
              resolve_value(scope, thread, inner_frame, item, wrapped_type)
            end
            resolved_values
          when GraphQL::TypeKinds::INTERFACE, GraphQL::TypeKinds::UNION
            resolved_type = type_defn.resolve_type(value, scope)

            if !resolved_type.is_a?(GraphQL::ObjectType)
              raise GraphQL::ObjectType::UnresolvedTypeError.new(type_defn, value)
            else
              resolve_value(scope, thread, frame, value, resolved_type)
            end
          when GraphQL::TypeKinds::OBJECT
            inner_frame = ExecFrame.new(
              node: frame.node,
              path: frame.path,
              value: value,
              type: type_defn,
            )
            resolve_selections(scope, thread, inner_frame)
          else
            raise("No ResolveValue for kind: #{type_defn.kind.name} (#{type_defn})")
          end
        end
      end
    end
  end
end
