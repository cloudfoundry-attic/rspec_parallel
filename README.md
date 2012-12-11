rspec_parallel
==============

run rspec examples in parallel
rspec_parallel user manual
================

What is rspec_parallel
------------

rspec_parallel is a ruby gem that allows to run rspec examples/tests in parallel.
1. Tests are distributed dynamically for each thread
2. Tests are executed alphabetically, rewrite RspecParallel.reorder_tests to change
3. Junit-format xml report is generated after each run
4. Re-run failures are supported
5. Integrate progressbar gem to show the execution progress

## Dependencies
1. progressbar >= 0.11.0

## _Tested Operating Systems_
1. Mac OS X 64bit, 10.6 and above
2. Ubuntu 10.04 LTS 64bit

Usage
-------------
1. gem install rspec_parallel (or add it into Gemfile)
2. Sample code:

```
require 'rspec_parallel'

options = {}
options[:thread_number] = 4 # default: 10
options[:env_list] = [] # you can pass different env vars to each thead
options[:filter] = {"tags" => "mysql,~slow", "pattern" => /(ruby|java)/} # filter tests by tags or regular expressions
options[:show_pending] = true # show all pending tests after the run
options[:rerun] = true # rerun failures of last run
options[:single_report] = true # for rerun, update a single report; if set to false, generate separate reports.

# all supported options and default values
# @options = {:thread_number => 4, :case_folder => "./spec/", :report_folder => "./reports/",
#             :filter => {}, :env_list => [], :show_pending => false, :rerun => false,
#             :single_report => false, :max_rerun_times => 10, :max_thread_number => 16,
#             :longevity_time => 0}.merge(options)
#

rp = RspecParallel.new(options)
rp.run_tests
```
