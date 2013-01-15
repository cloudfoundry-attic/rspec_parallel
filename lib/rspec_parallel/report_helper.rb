# generate or update report
module RParallel
  module ReportHelper

    def get_report_folder(base_folder, get_next = false)
      i = 0

      folders = Dir.glob("#{base_folder}/rerun*").sort
      unless folders.nil? || folders == []
        i = folders.last.split("rerun",2).last.to_i
      end

      if get_next
        i = i + 1
      end

      return base_folder if i == 0

      File.join(base_folder, "rerun#{i.to_s}")
    end

    def get_last_report_file(base_folder, single_report)
      if single_report
        return File.join(base_folder, "junitResult.xml")
      else
        report_folder = get_report_folder(base_folder, false)
        return File.join(report_folder, "junitResult.xml")
      end
    end

    def get_failed_cases(base_folder, single_report)
      queue = Queue.new

      last_report_file = get_last_report_file(base_folder, single_report)
      unless File.exists? last_report_file
        puts yellow("can't find result of last run")
        exit(1)
      end

      begin
        doc = Nokogiri::XML(open(last_report_file))
        doc.xpath("//result/suites/suite/cases/case").each do |c|
          unless c.xpath(".//errorDetails").empty?
            rerun_cmd = c.xpath(".//rerunCommand").text
            line = rerun_cmd.split('#')[0].gsub('rspec ', '').strip
            queue << line
          end
        end
      rescue
        puts red("invalid format of report xml")
        exit(1)
      end

      queue
    end

    def generate_reports(report_folder, time, case_info_list, options)
      %x[mkdir #{report_folder}] unless File.exists? report_folder
      report_file_path = File.join(report_folder, 'junitResult.xml')

      if options[:longevity] > 1 && options[:single_report]
        summary_doc = Nokogiri::XML(open(report_file_path, 'r')) do |config|
          config.default_xml.noblanks
        end
        summary_doc.search("//result/duration").remove
        summary_doc.search("//result/keepLongStdio").remove
      else
        builder = Nokogiri::XML::Builder.new("encoding" => 'UTF-8') do |xml|
          xml.result {
            xml.suites
          }
        end
        summary_doc = builder.doc
      end

      # reorder the tests by class_name
      class_name_list = []
      case_info_list.each do |case_info|
        class_name = case_info['class_name']
        class_name_list << class_name
      end
      class_name_list.uniq!
      class_name_list.sort!
      class_name_list.each do |class_name|
        temp_case_info_list = []
        case_info_list.each do |case_info|
          if case_info['class_name'] == class_name
            temp_case_info_list << case_info
          end
        end

        generate_single_file_report(report_folder, temp_case_info_list, options, summary_doc.at("//result/suites"))
      end

      if options[:rerun] && options[:single_report]
        last_report_file = get_last_report_file(options[:report_folder], options[:single_report])
        last_doc = Nokogiri::XML(open(last_report_file))
        doc = update_single_report(last_doc, case_info_list)
        fr = File.new(report_file_path, 'w')
        fr.puts doc.to_xml(:indent => 2)
        fr.close
        return
      end

      Nokogiri::XML::Builder.with(summary_doc.at("//result")) do |xml|
        xml.duration time
        xml.keepLongStdio "false"
      end

      fr = File.new(report_file_path, 'w')
      fr.puts summary_doc.to_xml(:indent => 2)
      fr.close
    end

    def update_single_report(doc, case_info_list)
      doc.xpath("//result/suites/suite/cases/case").each do |c1|
        unless c1.xpath(".//errorDetails").empty?
          test_name = c1.at_xpath(".//testName").text
          case_info_list.each do |c2|
            if test_name == c2['test_name']  #.encode({:xml => :attr})
              c1.at_xpath(".//duration").content = c2['duration']
              if c2['status'] == 'fail'
                text = c2['error_message'].gsub('Failure/Error: ', '') + "\n"
                text += c2['error_stack_trace'].gsub('# ', '')
                c1.at_xpath(".//errorStackTrace").content = text.strip
                c1.at_xpath(".//errorDetails").content = c2['error_details']
                c1.at_xpath(".//rerunCommand").content = c2['rerun_cmd'].strip
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
      doc
    end

    def generate_single_file_report(report_folder, case_info_list, options, suites_doc)
      return if case_info_list == []
      class_name = case_info_list[0]['class_name']
      file_name = File.join(report_folder, class_name.gsub(/:+/, '-') + '.xml')

      suite_duration = 0.0
      fail_num    = 0
      error_num   = 0
      pending_num = 0
      stdout = ''
      stderr = ''
      stdout_list    = []
      stderr_list    = []
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
          xml.name class_name.gsub(':', '_')
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

      longevity_report = options[:longevity] > 1 && options[:single_report]
      if longevity_report
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
        i = case_info_list.index { |c| c['test_desc'] == case_desc }
        case_info = case_info_list[i]
        if options[:longevity] == 0
          test_name = case_info['test_name']
        else
          test_name = "#{options[:longevity]}-"+case_info['test_name']
        end
        test_name += " (PENDING)" if case_info['status'] == 'pending'
        # test_name = test_name.encode({:xml => :attr})
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
                xml.text case_info['error_stack_trace'].gsub('# ', '').strip
              }
              xml.errorDetails case_info['error_details']
              xml.rerunCommand case_info['rerun_cmd'].strip
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
                xml.text case_info['error_stack_trace'].gsub('# ', '').strip
              }
              xml.rerunCommand case_info['rerun_cmd'].strip
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
end
