#encoding: UTF-8
$LOAD_PATH << File.dirname(__FILE__)
require 'progressbar'
require 'thread'
require 'find'
require 'nokogiri'

require 'rspec_parallel/color_helper'
require 'rspec_parallel/version'
include RParallel
include RParallel::ColorHelpers

class RspecParallel

  attr_reader         :case_number
  attr_reader         :failure_number
  attr_reader         :pending_number
  attr_reader         :case_info_list
  attr_reader         :interrupted

  attr_accessor       :thread_number
  attr_accessor       :max_rerun_times
  attr_accessor       :max_thread_number

  def initialize(options = {})
    @options = {:thread_number => 4, :case_folder => "./spec/", :report_folder => "./reports/",
                :filter => {}, :env_list => [], :show_pending => false, :rerun => false,
                :single_report => false, :random_order => false, :random_seed => nil,
                :max_rerun_times => 10, :max_thread_number => 16, :longevity_time => 0}.merge(options)
    @thread_number = @options[:thread_number]
    @max_rerun_times = @options[:max_rerun_times]
    @max_thread_number = @options[:max_thread_number]

    @longevity = @options[:longevity_time]
    @case_number = 0
    @failure_number = 0
    @pending_number = 0
    @interrupted = false
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
      @report_folder = get_single_folder("rerun", true)
    end

    @report_folder = @options[:report_folder] if @report_folder.nil?

    if @report_folder.include? "rerun#{@max_rerun_times + 1}"
      @return_message = "rerun task has been executed for #{@max_rerun_times}" +
                        " times, maybe you should start a new run"
      puts yellow(@return_message)
      return @return_message
    end

    filter = @options[:filter]
    if rerun
      get_failed_cases
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

    #CI: true - update ; default: false - new file
    generate_reports(end_time - start_time, rerun && single_report)

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

  def get_single_folder(folder_prefix, get_next=false)
    report_folder = @options[:report_folder]
    i = 0
    if folder_prefix == "rerun"
      folders = Dir.glob("#{report_folder}/rerun*").sort
      unless folders.nil? || folders == []
        i = folders.last.split("rerun",2).last.to_i
      end
    end

    if get_next
      i = i+1
    end

    if i == 0
      return report_folder
    end

    folder = File.join(report_folder, folder_prefix+"#{i.to_s}")

  end

  def get_failed_cases
    if !@options[:single_report]
      last_report_folder = get_single_folder("rerun", false)
      last_report_file_path = File.join(last_report_folder, "junitResult.xml")
    else
      last_report_file_path = File.join(@report_folder, "junitResult.xml")
    end
    unless File.exists? last_report_file_path
      puts yellow("can't find result of last run")
      exit(1)
    end
    begin
      @doc = Nokogiri::XML(open(last_report_file_path))
    rescue
      puts red("invalid format of report xml")
      exit(1)
    end

    @doc.xpath("//result/suites/suite/cases/case").each do |c|
      unless c.xpath(".//errorDetails").empty?
        rerun_cmd = c.xpath(".//rerunCommand").text
        line = rerun_cmd.split('#')[0].gsub('rspec ', '').strip
        @queue << line
      end
    end
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

  def generate_reports(time, update_report)
    %x[mkdir #{@report_folder}] unless File.exists? @report_folder

    report_file_path = File.join(@report_folder, 'junitResult.xml')
    if @longevity > 1 && @options[:single_report]
       summarydoc = Nokogiri::XML(open(report_file_path, 'r')) do |config|
         config.default_xml.noblanks
       end
       summarydoc.search("//result/duration").remove
       summarydoc.search("//result/keepLongStdio").remove
    elsif not update_report
      builder = Nokogiri::XML::Builder.new("encoding" => 'UTF-8') do |xml|
        xml.result {
          xml.suites
        }
      end
      summarydoc = builder.doc
    end

    class_name_list = []
    @case_info_list.each do |case_info|
      class_name = case_info['class_name']
      class_name_list << class_name
    end
    class_name_list.uniq!
    class_name_list.sort!
    class_name_list.each do |class_name|
      temp_case_info_list = []
      @case_info_list.each do |case_info|
        if case_info['class_name'] == class_name
          temp_case_info_list << case_info
        end
      end
      #CI: should insert into file while single_report == true
      is_update = @longevity > 1 && @options[:single_report]
      generate_single_file_report(temp_case_info_list, is_update, summarydoc.at("//result/suites"))
    end

    if update_report
      update_ci_report
      fr = File.new(report_file_path, 'w')
      fr.puts @doc.to_xml(:indent => 2)
      fr.close
    end

    Nokogiri::XML::Builder.with(summarydoc.at("//result")) do |xml|
      xml.duration time
      xml.keepLongStdio "false"
    end

    fr = File.new(report_file_path, 'w')
    fr.puts summarydoc.to_xml(:indent => 2)
    fr.close
  end

  def update_ci_report
    @doc.xpath("//result/suites/suite/cases/case").each do |c1|
      unless c1.xpath(".//errorDetails").empty?
        test_name = c1.at_xpath(".//testName").text
        @case_info_list.each do |c2|
          if test_name == c2['test_name'].encode({:xml => :attr})
            c1.at_xpath(".//duration").text = c2['duration']
            if c2['status'] == 'fail'
              text = c2['error_message'].gsub('Failure/Error: ', '') + "\n"
              text += c2['error_stack_trace'].gsub('# ', '')
              c1.at_xpath(".//errorStackTrace").text = text
              c1.at_xpath(".//errorDetails").text = c2['error_details']
              c1.at_xpath(".//rerunCommand").text = c2['rerun_cmd']
            else
              c1.search(".//errorDetails").remove
              c1.search(".//errorStackTrace").remove
              c1.search(".//rerunCommand").remove
            end
            break
          end
        end
      end
    end
  end

  def generate_single_file_report(case_info_list, is_update, suites_doc)
    return if case_info_list == []
    class_name = case_info_list[0]['class_name']
    file_name = File.join(@report_folder, class_name.gsub(/:+/, '-') + '.xml')
    name = class_name.gsub(':', '_')

    suite_duration = 0.0
    fail_num = 0
    error_num = 0
    pending_num = 0
    stdout = ''
    stderr = ''
    stdout_list = []
    stderr_list = []
    case_desc_list = []
    case_info_list.each do |case_info|
      suite_duration += case_info['duration']
      stdout_list << case_info['stdout']
      stderr_list << case_info['stderr']
      case_desc_list << case_info['test_desc']
      if case_info['status'] == 'fail'
        if case_info['error_message'].include? "expect"
          fail_num += 1
        else
          error_num += 1
        end
      elsif case_info['status'] == 'pending'
        pending_num += 1
      end
    end
    stdout_list.uniq!
    stderr_list.uniq!
    case_desc_list.sort!
    stdout_list.each {|s| stdout += s}
    stderr_list.each {|s| stderr += s}

    suite_builder = Nokogiri::XML::Builder.with(suites_doc) do |xml|
      xml.suite {
        xml.file file_name
        xml.name name
        if stdout.length > 0
          xml.stdout stdout
        else
          xml.stdout ""
        end
        if stderr.length > 0
          xml.stderr stderr
        else
          xml.stderr ""
        end
        xml.duration suite_duration
        xml.cases
      }
    end

    if is_update == true
      # update the testcase to the same report
      single_report = Nokogiri::XML(open(file_name)) do |config|
        config.default_xml.noblanks
      end
      # delete 'system-out' and 'system-err', using the new one
      single_report.search("//system-out").remove
      single_report.search("//system-err").remove
    else
      builder = Nokogiri::XML::Builder.new(:encoding => 'UTF-8') do |xml|
        xml.testsuite(:name  => class_name,
                      :tests => case_info_list.size,
                      :time  => suite_duration,
                      :failures=> fail_num,
                      :errors  => error_num,
                      :skipped => pending_num)
      end
      single_report = builder.doc
    end

    case_desc_list.each do |case_desc|
      i = case_info_list.index {|c| c['test_desc'] == case_desc}
      case_info = case_info_list[i]
      if @longevity == 0
        test_name = case_info['test_name']
      else
        test_name = "#{@longevity}-"+case_info['test_name']
      end
      test_name += " (PENDING)" if case_info['status'] == 'pending'
      test_name = test_name.encode({:xml => :attr})
      if case_info['status'] == 'fail'
        if case_info['error_message'].include? "expected"
          type = "RSpec::Expectations::ExpectationNotMetError"
        elsif case_info['error_message'].include? "RuntimeError"
          type = "RuntimeError"
        else
          type = "UnknownError"
        end
      end
      # add new case into suite report for summary report
      Nokogiri::XML::Builder.with(suite_builder.doc.at("//cases")) do |xml|
        xml.case {
          xml.duration case_info['duration']
          xml.className class_name
          xml.testName test_name
          xml.skipped case_info['status'] == 'pending'
          if case_info['status'] == 'fail'
            xml.errorStackTrace  {
              xml.text case_info['error_message'].gsub('Failure/Error: ', '')
              xml.text case_info['error_stack_trace'].gsub('# ', '')
            }
            xml.errorDetails case_info['error_details']
            xml.rerunCommand case_info['rerun_cmd']
          end
          xml.failedSince '0'
        }
      end

      # add new case into single report
      Nokogiri::XML::Builder.with(single_report.at("testsuite")) do |xml|
        xml.testcase(:name => test_name, :time => case_info['duration']) {
          if case_info['status'] == 'pending'
            xml.skipped
          elsif case_info['status'] == 'fail'
            xml.failure(:type => type, :message => case_info['error_details']) {
              xml.text case_info['error_message'].gsub('Failure/Error: ', '')
              xml.text case_info['error_stack_trace'].gsub('# ', '')
            }
            xml.rerunCommand case_info['rerun_cmd']
          end
        }
      end
    end

    Nokogiri::XML::Builder.with(single_report.at("testsuite")) do |xml|
      if stdout.length > 0
        xml.send(:'system-out', stdout)
      else
        xml.send(:'system-out', "")
      end
      if stderr.length > 0
        xml.send(:'system-err', stderr)
      else
        xml.send(:'system-err', "")
      end
    end
    ff = File.new(file_name, 'w')
    ff.puts single_report.to_xml(:indent => 2)
    ff.close
  end
end
