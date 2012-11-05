Gem::Specification.new do |s|
  s.name        = 'rspec_parallel'
  s.version     = '0.1.2'
  s.date        = '2012-11-27'
  s.summary     = "rspec parallel"
  s.description = "parallel all rspec examples"
  s.authors     = ["Michael Zhang"]
  s.email       = 'zhangcheng@rbcon.com'
  s.files       = ["lib/rspec_parallel.rb", "lib/color_helper.rb"]
  s.add_dependency('progressbar', '>=0.11.0')
  s.homepage    =
    'http://rubygems.org/gems/rspec_parallel'
end
