Gem::Specification.new do |s|
  s.name        = 'rspec_parallel'
  s.version     = '0.1.5'
  s.date        = '2012-12-07'
  s.summary     = "rspec parallel"
  s.description = "parallel all rspec examples"
  s.author       = "VMware"
  s.email        = "support@vmware.com"
  s.homepage     = "http://www.vmware.com"
  s.files       = ["lib/rspec_parallel.rb", "lib/color_helper.rb"]
  s.add_dependency('progressbar', '>=0.11.0')
end
