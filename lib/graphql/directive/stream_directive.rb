GraphQL::Directive::StreamDirective = GraphQL::Directive.define do
  name "stream"
  description "Push items from this list in sequential patches"
  locations([GraphQL::Directive::FIELD])

  # This doesn't make any sense in this context
  # But it's required for DirectiveResolution
  include_proc -> (args) { true }
end
