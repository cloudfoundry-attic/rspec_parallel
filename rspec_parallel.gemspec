require File.dirname(__FILE__) + "/lib/rspec_parallel/version"

Gem::Specification.new do |s|
  s.name         = 'rspec_parallel'
  s.version      = RParallel::VERSION
  s.platform     = Gem::Platform::RUBY
  s.summary      = "rspec parallel"
  s.description  = "parallel all rspec examples"
  s.author       = "VMware"
  s.email        = "support@vmware.com"
  s.homepage     = "http://www.vmware.com"

  s.files        = `git ls-files`.split("\n")
  s.add_dependency('progressbar', '>=0.11.0')
end
