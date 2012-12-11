require File.dirname(__FILE__) + '/../lib/rspec_parallel'

describe "smoke test for rspec_parallel" do

  it "no case to run" do
    options = {}
    options[:case_folder] = "../lib"
    rp = RspecParallel.new(options)
    response = rp.run_tests
    response.should == "no cases to run, exit."
  end

end
