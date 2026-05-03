$LOAD_PATH.unshift File.expand_path("..", __dir__)

RSpec.configure do |c|
  c.expect_with(:rspec) { |e| e.syntax = :expect }
  c.disable_monkey_patching!
  c.warnings = true
  c.order = :random
end
