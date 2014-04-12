# encoding: UTF-8
class Fluent::StatsOutput < Fluent::Output
  Fluent::Plugin.register_output('stats', self)

  # To support log_level option implemented by Fluentd v0.10.43
  unless method_defined?(:log)
    define_method("log") { $log }
  end

  def initialize
    super
    require 'pathname'
  end

  config_param :sum, :string, :default => nil
  config_param :max, :string, :default => nil
  config_param :min, :string, :default => nil
  config_param :avg, :string, :default => nil
  config_param :sum_keys, :string, :default => nil
  config_param :max_keys, :string, :default => nil
  config_param :min_keys, :string, :default => nil
  config_param :avg_keys, :string, :default => nil
  config_param :sum_suffix, :string, :default => ""
  config_param :max_suffix, :string, :default => ""
  config_param :min_suffix, :string, :default => ""
  config_param :avg_suffix, :string, :default => ""
  config_param :interval, :time, :default => 5
  config_param :tag, :string, :default => nil
  config_param :add_tag_prefix, :string, :default => nil
  config_param :remove_tag_prefix, :string, :default => nil
  config_param :add_tag_suffix, :string, :default => nil
  config_param :remove_tag_suffix, :string, :default => nil
  config_param :aggregate, :string, :default => 'tag'
  config_param :store_file, :string, :default => nil
  config_param :zero_emit, :bool, :default => false

  attr_accessor :matches
  attr_accessor :saved_duration
  attr_accessor :saved_at
  attr_accessor :last_checked

  def configure(conf)
    super

    @interval = @interval.to_i
    @sum = Regexp.new(@sum) if @sum
    @max = Regexp.new(@max) if @max
    @min = Regexp.new(@min) if @min
    @avg = Regexp.new(@avg) if @avg
    @sum_keys = @sum_keys ? @sum_keys.split(',') : []
    @max_keys = @max_keys ? @max_keys.split(',') : []
    @min_keys = @min_keys ? @min_keys.split(',') : []
    @avg_keys = @avg_keys ? @avg_keys.split(',') : []

    unless ['tag', 'all'].include?(@aggregate)
      raise Fluent::ConfigError, "aggregate allows tag/all"
    end

    case @aggregate
    when 'all'
      raise Fluent::ConfigError, "tag must be specified for aggregate all" if @tag.nil?
    end

    if @tag.nil? and @add_tag_prefix.nil? and @remove_tag_prefix.nil? and @add_tag_suffix.nil? and @remove_tag_suffix.nil?
      @add_tag_prefix = 'stats' # not ConfigError for lower version compatibility
    end
    @tag_proc = tag_proc

    @matches = {}
    @mutex = Mutex.new
  end

  def initial_matches(prev_matches = nil)
    if @zero_emit && prev_matches
      matches = {}
      prev_matches.keys.each do |tag|
        next unless prev_matches[tag][:count] > 0 # Prohibit to emit anymore
        matches[tag] = { :count => 0, :sum => {}, :max => {}, :min => {}, :avg => {} }
        # ToDo: would want default configuration for :max, :min
        prev_matches[tag][:sum].keys.each {|key| matches[tag][:sum][key] = 0 }
        prev_matches[tag][:max].keys.each {|key| matches[tag][:max][key] = 0 }
        prev_matches[tag][:min].keys.each {|key| matches[tag][:min][key] = 0 }
        prev_matches[tag][:avg].keys.each {|key| matches[tag][:avg][key] = 0 }
      end
      matches
    else
      {}
    end
  end

  def start
    super
    load_status(@store_file, @interval) if @store_file
    @watcher = Thread.new(&method(:watcher))
  end

  def shutdown
    super
    @watcher.terminate
    @watcher.join
    save_status(@store_file) if @store_file
  end

  # Called when new line comes. This method actually does not emit
  def emit(tag, es, chain)
    _tag = tag
    tag = 'all' if @aggregate == 'all'
    # stats
    matches = { :count => 0, :sum => {}, :max => {}, :min => {}, :avg => {} }
    es.each do |time, record|
      record = stringify_keys(record)
      @sum_keys.each do |key|
        next unless record[key] and value = record[key].to_f
        matches[:sum][key] = sum(matches[:sum][key], value)
      end
      @max_keys.each do |key|
        next unless record[key] and value = record[key].to_f
        matches[:max][key] = max(matches[:max][key], value)
      end
      @min_keys.each do |key|
        next unless record[key] and value = record[key].to_f
        matches[:min][key] = min(matches[:min][key], value)
      end
      @avg_keys.each do |key|
        next unless record[key] and value = record[key].to_f
        matches[:avg][key] = sum(matches[:avg][key], value)
      end
      record.keys.each do |key|
        key = key.to_s
        value = record[key].to_f
        if @sum and @sum.match(key)
          matches[:sum][key] = sum(matches[:sum][key], value)
        end
        if @max and @max.match(key)
          matches[:max][key] = max(matches[:max][key], value)
        end
        if @min and @min.match(key)
          matches[:min][key] = min(matches[:min][key], value)
        end
        if @avg and @avg.match(key)
          matches[:avg][key] = sum(matches[:avg][key], value) # sum yet
        end
      end if @sum || @max || @min || @avg
      matches[:count] += 1
    end

    # thread safe merge
    @matches[tag] ||= { :count => 0, :sum => {}, :max => {}, :min => {}, :avg => {} }
    @mutex.synchronize do
      matches[:sum].keys.each do |key|
        @matches[tag][:sum][key] = sum(@matches[tag][:sum][key], matches[:sum][key])
      end
      matches[:max].keys.each do |key|
        @matches[tag][:max][key] = max(@matches[tag][:max][key], matches[:max][key])
      end
      matches[:min].keys.each do |key|
        @matches[tag][:min][key] = min(@matches[tag][:min][key], matches[:min][key])
      end
      matches[:avg].keys.each do |key|
        @matches[tag][:avg][key] = sum(@matches[tag][:avg][key], matches[:avg][key]) # sum yet
      end
      @matches[tag][:count] += matches[:count]
    end

    log.trace "out_stats: tag:#{_tag} @matches:#{@matches}"

    chain.next
  rescue => e
    log.warn "out_stats: #{e.class} #{e.message} #{e.backtrace.first}"
  end

  # thread callback
  def watcher
    # instance variable, and public accessable, for test
    @last_checked ||= Fluent::Engine.now
    while (sleep 0.5)
      begin
        if Fluent::Engine.now - @last_checked >= @interval
          report_time do
            @last_checked = Fluent::Engine.now
            flush_emit
          end
        end
      rescue => e
        log.warn "out_stats: #{e.class} #{e.message} #{e.backtrace.first}"
      end
    end
  end

  # This method is the real one to emit
  def flush_emit
    time = Fluent::Engine.now
    flushed_matches = {}
    @mutex.synchronize do
      flushed_matches, @matches = @matches, initial_matches(@matches)
    end
    log.trace("out_stats: flushed_matches:#{flushed_matches} @matches:#{@matches}") unless flushed_matches.empty?

    flushed_matches.each do |tag, matches|
      emit_tag = @tag_proc.call(tag)
      report_time(" emit_tag:#{emit_tag} matches:#{matches}") do
        output = generate_output(matches)
        Fluent::Engine.emit(emit_tag, time, output) if output and !output.empty?
      end
    end
  end

  def generate_output(matches)
    return nil if matches.empty?
    output = {}
    matches[:sum].keys.each do |key|
      output[key + @sum_suffix] = matches[:sum][key]
    end
    matches[:max].keys.each do |key|
      output[key + @max_suffix] = matches[:max][key]
    end
    matches[:min].keys.each do |key|
      output[key + @min_suffix] = matches[:min][key]
    end
    matches[:avg].keys.each do |key|
      output[key + @avg_suffix] = matches[:avg][key]
      output[key + @avg_suffix] /= matches[:count].to_f if matches[:count] > 0
    end
    output
  end

  def sum(a, b)
    [a, b].compact.inject(:+)
  end

  def max(a, b)
    [a, b].compact.max
  end

  def min(a, b)
    [a, b].compact.min
  end

  # Store internal status into a file
  #
  # @param [String] file_path
  def save_status(file_path)
    return unless file_path

    begin
      Pathname.new(file_path).open('wb') do |f|
        @saved_at = Fluent::Engine.now
        @saved_duration = @saved_at - @last_checked
        Marshal.dump({
          :matches          => @matches,
          :saved_at         => @saved_at,
          :saved_duration   => @saved_duration,
          :aggregate        => @aggregate,
          :sum              => @sum,
          :max              => @max,
          :min              => @min,
          :avg              => @avg,
        }, f)
      end
    rescue => e
      log.warn "out_stats: Can't write store_file #{e.class} #{e.message}"
    end
  end

  # Load internal status from a file
  #
  # @param [String] file_path
  # @param [Interger] interval
  def load_status(file_path, interval)
    return unless (f = Pathname.new(file_path)).exist?

    begin
      f.open('rb') do |f|
        stored = Marshal.load(f)
        if stored[:aggregate] == @aggregate and
          stored[:sum] == @sum and
          stored[:max] == @max and
          stored[:min] == @min and
          stored[:avg] == @avg

          if !stored[:matches].empty? and !stored[:matches].first[1].has_key?(:max)
            log.warn "out_stats: stored data does not have compatibility with the current version. ignore stored data"
            return
          end

          if Fluent::Engine.now <= stored[:saved_at] + interval
            @matches = stored[:matches]
            @saved_at = stored[:saved_at]
            @saved_duration = stored[:saved_duration]
            # for lower compatibility
            if counts = stored[:counts]
              @matches.keys.each {|tag| @matches[tag][:count] = counts[tag] }
            end

            # skip the saved duration to continue counting
            @last_checked = Fluent::Engine.now - @saved_duration
          else
            log.warn "out_stats: stored data is outdated. ignore stored data"
          end
        else
          log.warn "out_stats: configuration param was changed. ignore stored data"
        end
      end
    rescue => e
      log.warn "out_stats: Can't load store_file #{e.class} #{e.message}"
    end
  end

  private
  def transform_keys(hash)
    result = {}
    hash.each_key do |key|
      result[yield(key)] = hash[key]
    end
    result
  end

  def stringify_keys(hash)
    transform_keys(hash) { |key| key.to_s }
  end

  def tag_proc
    rstrip = Proc.new {|str, substr| str.chomp(substr) }
    lstrip = Proc.new {|str, substr| str.start_with?(substr) ? str[substr.size..-1] : str }
    tag_prefix = "#{rstrip.call(@add_tag_prefix, '.')}." if @add_tag_prefix
    tag_suffix = ".#{lstrip.call(@add_tag_suffix, '.')}" if @add_tag_suffix
    tag_prefix_match = "#{rstrip.call(@remove_tag_prefix, '.')}." if @remove_tag_prefix
    tag_suffix_match = ".#{lstrip.call(@remove_tag_suffix, '.')}" if @remove_tag_suffix
    tag_fixed = @tag if @tag
    if tag_fixed
      Proc.new {|tag| tag_fixed }
    elsif tag_prefix_match and tag_suffix_match
      Proc.new {|tag| "#{tag_prefix}#{rstrip.call(lstrip.call(tag, tag_prefix_match), tag_suffix_match)}#{tag_suffix}" }
    elsif tag_prefix_match
      Proc.new {|tag| "#{tag_prefix}#{lstrip.call(tag, tag_prefix_match)}#{tag_suffix}" }
    elsif tag_suffix_match
      Proc.new {|tag| "#{tag_prefix}#{rstrip.call(tag, tag_suffix_match)}#{tag_suffix}" }
    else
      Proc.new {|tag| "#{tag_prefix}#{tag}#{tag_suffix}" }
    end
  end

  def report_time(msg = nil, &blk)
    t = Time.now
    output = yield
    log.debug sprintf("out_stats: elapsed_time:%.2f thread_id:%s%s caller:%s", (Time.now - t).to_f, Thread.current.object_id, msg, caller()[0])
    output
  end
end
