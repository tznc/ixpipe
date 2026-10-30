# frozen_string_literal: true

require 'json'
require 'stringio'

# Runs a Script tool's Ruby code: unsandboxed, in the user's Ruby.
#
# `inputs` maps each input to rows (an array of hashes) or, with the parquet
# format, to its Parquet file. The script sets `output`: an array of hashes
# or a hash of column arrays.
module IxpipeRunner
  SCRIPT = 'script.rb'
  MAX_TEXT = 1_000_000
  MISSING = Object.new.freeze

  module_function

  def run(code, inputs, output_path, format)
    out = StringIO.new
    err = StringIO.new
    result = { 'stdout' => '', 'stderr' => '', 'error' => nil, 'written' => nil }
    stdout, stderr = $stdout, $stderr
    begin
      data = inputs.to_h { |name, path| [name, format == 'parquet' ? path : read(path)] }
      scope = sandbox_binding
      scope.local_variable_set(:inputs, data)
      scope.local_variable_set(:output_path, output_path)
      scope.local_variable_set(:output, MISSING)
      $stdout, $stderr = out, err
      eval(code, scope, SCRIPT, 1) # rubocop:disable Security/Eval
      $stdout, $stderr = stdout, stderr
      result['written'] = write(scope.local_variable_get(:output), output_path, format)
    rescue Exception => e # rubocop:disable Lint/RescueException
      result['error'] = failure(e)
    ensure
      $stdout, $stderr = stdout, stderr
    end
    result['stdout'] = out.string[0, MAX_TEXT]
    result['stderr'] = err.string[0, MAX_TEXT]
    result
  end

  def sandbox_binding
    binding
  end

  def read(path)
    File.foreach(path).reject { |l| l.strip.empty? }.map { |l| JSON.parse(l) }
  end

  def write(output, path, format)
    if output.equal?(MISSING)
      return { 'format' => 'parquet' } if format == 'parquet' && File.exist?(path)

      return { 'missing' => true }
    end
    case output
    when Hash
      columns = output.keys.map(&:to_s)
      values = output.values.map(&:to_a)
      return { 'bad' => "output's columns have different lengths" } if values.map(&:length).uniq.length > 1

      rows = (values.first || []).each_index.map { |i| columns.zip(values.map { |v| v[i] }).to_h }
    when Array
      bad = output.find { |r| !r.is_a?(Hash) }
      return { 'bad' => "output is an array of #{bad.class}, not of hashes" } unless bad.nil?

      rows = output
      columns = rows.flat_map { |r| r.keys.map(&:to_s) }.uniq
    else
      return { 'bad' => "output is a #{output.class}" }
    end
    File.open(path, 'w') { |f| rows.each { |r| f.puts(JSON.generate(r)) } }
    { 'format' => 'jsonl', 'columns' => columns, 'rows' => rows.length }
  end

  def failure(error)
    trace = ([error.message] + (error.backtrace || [])).join("\n")
    line = trace[/script\.rb:(\d+)/, 1]
    {
      'type' => error.class.name,
      'message' => error.message,
      'line' => line&.to_i,
      'traceback' => "#{error.class}: #{trace}"[0, MAX_TEXT]
    }
  end
end
