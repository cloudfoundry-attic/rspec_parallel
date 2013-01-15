#encoding: UTF-8
$LOAD_PATH << File.dirname(__FILE__)
require 'progressbar'
require 'thread'
require 'find'
require 'nokogiri'

require 'rspec_parallel/color_helper'
require 'rspec_parallel/version'
require 'rspec_parallel/report_helper'
include RParallel
include RParallel::ColorHelper
include RParallel::ReportHelper

class RspecParallel

  attr_reader         :case_number
  attr_reader         :failure_number
  attr_reader         :pending_number
  attr_reader         :case_info_list
  attr_reader         :interrupted

  attr_accessor       :thread_number
  attr_accessor       :max_thread_number

  def initialize(options = {})
    @options = {:thread_number => 4, :case_folder => "./spec/", :report_folder => "./reports/",
                :filter => {}, :env_list => [], :show_pending => false, :rerun => false,
                :single_report => false, :random_order => false, :random_seed => nil,
                :max_thread_number => 16, :longevity => 0}.merge(options)
    @thread_number = @options[:thread_number]
    @max_thread_number = @options[:max_thread_number]

    @case_number = 0
    @failure_number = 0
    @pending_number = 0
    @interrupted = false
    @target = @options[:target]
  end

  def run_tests()
    start_time = Time.now # timer of rspec task
    @queue = Queue.new # store all tests to run
    @case_info_list = [] # store results of all tests
    @lock = Mutex.new # use lock to avoid output mess up
    @return_message = "ok"

    if @thread_number < 1
      @return_message = "thread_number can't be less than 1"
      puts red(@return_message)
      return @return_message
    elsif @thread_number > @max_thread_number
      @return_message = "thread_number can't be greater than #{@max_thread_number}"
      puts red(@return_message)
      return @return_message
    end
    puts yellow("threads number: #{@thread_number}\n")

    rerun = @options[:rerun]
    single_report = @options[:single_report]

    if !single_report && rerun
      @report_folder = get_report_folder(@options[:report_folder], true)
    end

    @report_folder = @options[:report_folder] if @report_folder.nil?

    filter = @options[:filter]
    if rerun
      @queue = get_failed_cases(@options[:report_folder], single_report)
    else
      parse_case_list(filter)
    end

    if @queue.empty?
      @return_message = "no cases to run, exit."
      puts yellow(@return_message)
      return @return_message
    end

    pbar = ProgressBar.new("0/#{@queue.size}", @queue.size, $stdout)
    pbar.format_arguments = [:title, :percentage, :bar, :stat]
    failure_list = []
    pending_list = []

    Thread.abort_on_exception = false
    threads = []

    @thread_number.times do |i|
      threads << Thread.new do
        until @queue.empty?
          task = @queue.pop
          env_extras = {}
          env_list = @options[:env_list]
          if env_list && env_list[i]
            env_extras = env_list[i]
          end
          t1 = Time.now
          task_output = run_task(task, env_extras)
          t2 = Time.now
          case_info = parse_case_log(task_output)
          unless case_info
            puts task_output
            next
          end
          case_info['duration'] = t2 - t1
          @case_info_list << case_info

          if case_info['status'] == 'fail'
            @lock.synchronize do
              @failure_number += 1
              failure_list << case_info

              # print failure immediately during the execution
              $stdout.print "\e[K"
              if @failure_number == 1
                $stdout.print "Failures:\n\n"
              end
              puts "  #{@failure_number}) #{case_info['test_name']}"
              $stdout.print "#{red(case_info['error_message'])}"
              $stdout.print "#{cyan(case_info['error_stack_trace'])}"
              $stdout.print red("     (Failure time: #{Time.now})\n\n")
            end
          elsif case_info['status'] == 'pending'
            @lock.synchronize do
              @pending_number += 1
              pending_list << case_info
            end
          end
          @case_number += 1
          pbar.inc
          pbar.instance_variable_set("@title", "#{pbar.current}/#{pbar.total}")
        end
      end
      # ramp up user threads one by one
      sleep 0.1
    end

    begin
      threads.each { |t| t.join }
    rescue Interrupt
      puts yellow("catch Ctrl+C, will exit gracefully")
      @interrupted = true
    end
    pbar.finish

    # print pending cases if configured
    show_pending = @options[:show_pending]
    if show_pending && @pending_number > 0
      $stdout.print "\n"
      puts "Pending:"
      pending_list.each {|case_info|
        puts "  #{yellow(case_info['test_name'])}\n"
        $stdout.print cyan("#{case_info['pending_info']}")
      }
    end

    # print total time and summary result
    end_time = Time.now
    puts "\nFinished in #{format_time(end_time-start_time)}\n"
    if @failure_number > 0
      $stdout.print red("#{@case_number} examples, #{@failure_number} failures")
      $stdout.print red(", #{@pending_number} pending") if @pending_number > 0
    elsif @pending_number > 0
      $stdout.print yellow("#{@case_number} examples, #{@failure_number} failures, #{@pending_number} pending")
    else
      $stdout.print green("#{@case_number} examples, 0 failures")
    end
    $stdout.print "\n"

    # print rerun command of failed examples
    unless failure_list.empty?
      $stdout.print "\nFailed examples:\n\n"
      failure_list.each do |case_info|
        $stdout.print red(case_info['rerun_cmd'].split(' # ')[0])
        $stdout.print cyan(" # #{case_info['test_name']}\n")
      end
    end

    # CI: true - update ; default: false - new file
    generate_reports(@report_folder, end_time - start_time, @case_info_list, @options)

    @return_message
  end

  def get_case_list
    case_folder = @options[:case_folder]
    case_list = []
    Find.find(case_folder) { |filename|
      unless filename.include? "_spec.rb"
        next
      end
      f = File.read(filename.strip).force_encoding("ISO-8859-1").encode("utf-8", replace: nil)

      # try to get tags of describe level
      describe_text = f.scan(/describe [\s\S]*? do/)[0]
      describe_tags = []
      temp = describe_text.scan(/[,\s]:(\w+)/)
      unless temp == nil
        temp.each do |t|
          describe_tags << t[0]
        end
      end

      # get cases of normal format: "it ... do"
      cases = f.scan(/(it (["'])([\s\S]*?)\2[\s\S]*? do)/)
      line_number = 0
      if cases
        cases.each { |c1|
          c = c1[0]
          tags = []
          draft_tags = c.scan(/[,\s]:(\w+)/)
          draft_tags.each { |tag|
            tags << tag[0]
          }
          tags += describe_tags
          tags.uniq

          i = 0
          cross_line = false
          f.each_line { |line|
            i += 1
            if i <= line_number && line_number > 0
              next
            end
            if line.include? c1[2]
              if line.strip.end_with? " do"
                case_hash = {"line" => "#{filename.strip}:#{i}", "tags" => tags}
                case_list << case_hash
                line_number = i
                cross_line = false
                break
              else
                cross_line = true
              end
            end
            if cross_line && (line.strip.end_with? " do")
              case_hash = {"line" => "#{filename.strip}:#{i}", "tags" => tags}
              case_list << case_hash
              line_number = i
              cross_line = false
              break
            end
          }
        }
      end

      # get cases of another format: "it {...}"
      cases = f.scan(/it \{[\s\S]*?\}/)
      line_number = 0
      if cases
        cases.each { |c|
          i = 0
          f.each_line { |line|
            i += 1
            if i <= line_number && line_number > 0
              next
            end
            if line.include? c
              case_hash = {"line" => "#{filename.strip}:#{i}", "tags" => describe_tags}
              case_list << case_hash
              line_number = i
              break
            end
          }
        }
      end
    }
    case_list
  end

  def parse_case_list(filter)
    all_case_list = get_case_list
    pattern_filter_list = []
    tags_filter_list = []

    if filter["pattern"]
      all_case_list.each { |c|
        if c["line"].match(filter["pattern"])
          pattern_filter_list << c
        end
      }
    else
      pattern_filter_list = all_case_list
    end

    if filter["tags"]
      include_tags = []
      exclude_tags = []
      all_tags = filter["tags"].split(",")
      all_tags.each { |tag|
        if tag.start_with? "~"
          exclude_tags << tag.gsub("~", "")
        else
          include_tags << tag
        end
      }
      pattern_filter_list.each { |c|
        if (include_tags.length == 0 || (c["tags"] - include_tags).length < c["tags"].length) &&
            ((c["tags"] - exclude_tags).length == c["tags"].length)
          tags_filter_list << c
        end
      }
    else
      tags_filter_list = pattern_filter_list
    end

    tags_filter_list = random_tests(tags_filter_list) if @options[:random_order]

    tags_filter_list = reorder_tests(tags_filter_list)

    tags_filter_list.each { |t|
      @queue << t["line"]
    }
  end

  def run_task(task, env_extras)
    cmd = [] # Preparing command for popen
    cmd << ENV.to_hash.merge(env_extras)
    cmd += ["bundle", "exec", "rspec", "-f", "d", "--color", task]
    cmd

    output = ""
    IO.popen(cmd, :err => [:child, :out]) do |io|
      output << io.read
    end

    output
  end

  def random_tests(case_list)
    if @options[:random_seed]
      seed = @options[:random_seed].to_i
    else
      seed = Time.now.to_i
    end
    puts yellow("running tests randomly with the seed: #{seed}")
    rand_num = Random.new(seed)

    random_case_list = []
    case_list.sort_by { rand_num.rand }.each do |c|
      random_case_list << c
    end
    random_case_list
  end

  def reorder_tests(case_list)
    return case_list
  end

  def format_time(t)
    time_str = ''
    time_str += (t / 3600).to_i.to_s + " hours " if t > 3600
    time_str += (t % 3600 / 60).to_i.to_s + " minutes " if t > 60
    time_str += (t % 60).to_f.round(2).to_s + " seconds"
    time_str
  end

  def parse_case_log(str)
    return nil unless str =~ /1 example/
    result = {}
    logs = []
    str.each_line {|l| logs << l}
    return nil if logs == []

    stderr = ''
    unless logs[0].start_with? 'Run options:'
      clear_logs = []
      logs_start = false
      for i in 0..logs.length-1
        if logs[i].strip.start_with? 'Run options:'
          logs_start = true
        end
        if logs_start
          clear_logs << logs[i]
        else
          stderr += logs[i]
        end
      end
      logs = clear_logs
    end
    result['stderr'] = stderr

    stdout = ''
    if logs[4].strip != ''
      clear_logs = []
      stdout_start = true
      for i in 0..logs.length-1
        if i < 3
          clear_logs << logs[i]
        elsif stdout_start && logs[i+1].strip == ''
          clear_logs << logs[i]
          stdout_start = false
        elsif !stdout_start
          clear_logs << logs[i]
        else
          stdout += logs[i]
        end
      end
      logs = clear_logs
    end
    result['stdout'] = stdout

    result['class_name'] = logs[2].strip
    result['test_desc'] = logs[3].gsub(/\((FAILED|PENDING).+\)/, '').strip
    result['test_name'] = result['class_name'] + ' ' + result['test_desc']

    if logs[-1].include? '1 pending'
      result['status'] = 'pending'
      pending_info = ''
      for i in 7..logs.length-4
        next if logs[i].strip == ''
        pending_info += logs[i]
      end
      result['pending_info'] = pending_info
    elsif logs[-1].include? '0 failures'
      result['status'] = 'pass'
    elsif logs[-1].start_with? 'rspec '
      result['status'] = 'fail'
      result['rerun_cmd'] = logs[-1]
      error_message = logs[8]
      error_stack_trace = ''
      for i in 9..logs.length-8
        next if logs[i].strip == ''
        if logs[i].strip.start_with? '# '
          error_stack_trace += logs[i]
        else
          error_message += logs[i]
        end
      end
      error_message.each_line do |l|
        next if l.include? 'Error:'
        result['error_details'] = l.strip
        break
      end
      if error_message.index(result['error_details']) < error_message.length - result['error_details'].length - 10
        result['error_details'] += "..."
      end
      result['error_message'] = error_message
      result['error_stack_trace'] = error_stack_trace
    else
      result['status'] = 'unknown'
    end

    result
  end

end
