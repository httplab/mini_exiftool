# -- encoding: utf-8 --
#
# MiniExiftool
#
# This library is wrapper for the Exiftool command-line
# application (http://www.sno.phy.queensu.ca/~phil/exiftool/)
# written by Phil Harvey.
# Read and write access is done in a clean OO manner.
#
# Author: Jan Friedrich
# Copyright (c) 2007-2013 by Jan Friedrich
# Licensed under the GNU LESSER GENERAL PUBLIC LICENSE,
# Version 2.1, February 1999
#

require 'fileutils'
require 'json'
require 'pstore'
require 'rational'
require 'rbconfig'
require 'set'
require 'tempfile'
require 'time'

# Simple OO access to the Exiftool command-line application.
class MiniExiftool

  # Name of the Exiftool command-line application
  @@cmd = 'exiftool'

  # Hash of the standard options used when call MiniExiftool.new
  @@opts = { :numerical => false, :composite => true, :ignore_minor_errors => false,
   :replace_invalid_chars => false, :timestamps => Time }

  # Encoding of the filesystem (filenames in command line)
  @@fs_enc = Encoding.find('filesystem')

  attr_reader :filename
  attr_accessor :numerical, :composite, :ignore_minor_errors, :errors,
    :replace_invalid_chars, :timestamps

  VERSION = '2.1.0'

  # +opts+ support at the moment
  # * <code>:numerical</code> for numerical values, default is +false+
  # * <code>:composite</code> for including composite tags while loading,
  #   default is +true+
  # * <code>:ignore_minor_errors</code> ignore minor errors (See -m-option
  #   of the exiftool command-line application, default is +false+)
  # * <code>:coord_format</code> set format for GPS coordinates (See
  #   -c-option of the exiftool command-line application, default is +nil+
  #   that means exiftool standard)
  # * <code>:replace_invalid_chars</code> replace string for invalid
  #   UTF-8 characters or +false+ if no replacing should be done,
  #   default is +false+
  # * <code>:timestamps</code> generating DateTime objects instead of
  #   Time objects if set to <code>DateTime</code>, default is +Time+
  #
  #   <b>ATTENTION:</b> Time objects are created using <code>Time.local</code>
  #   therefore they use <em>your local timezone</em>, DateTime objects instead
  #   are created <em>without timezone</em>!
  def initialize filename=nil, opts={}
    opts = @@opts.merge opts
    @numerical = opts[:numerical]
    @composite = opts[:composite]
    if opts[:convert_encoding]
      warn 'Option :convert_encoding is not longer supported!'
      warn 'Please use the String#encod* methods.'
    end
    @ignore_minor_errors = opts[:ignore_minor_errors]
    @timestamps = opts[:timestamps]
    @coord_format = opts[:coord_format]
    @replace_invalid_chars = opts[:replace_invalid_chars]
    @values = TagHash.new
    @tag_names = TagHash.new
    @changed_values = TagHash.new
    @errors = TagHash.new
    load filename unless filename.nil?
  end

  def initialize_from_hash hash # :nodoc:
    hash.each_pair do |tag,value|
      set_value tag, convert_after_load(value)
    end
    set_attributes_by_heuristic
    self
  end

  def initialize_from_json json # :nodoc:
    @output = json
    @errors.clear
    parse_output
    self
  end

  # Load the tags of filename.
  def load filename
    MiniExiftool.setup
    unless filename && File.exist?(filename)
      raise MiniExiftool::Error.new("File '#{filename}' does not exist.")
    end
    if File.directory?(filename)
      raise MiniExiftool::Error.new("'#{filename}' is a directory.")
    end
    @filename = filename
    @values.clear
    @tag_names.clear
    @changed_values.clear
    params = '-j '
    params << (@numerical ? '-n ' : '')
    params << (@composite ? '' : '-e ')
    params << (@coord_format ? "-c \"#{@coord_format}\"" : '')
    if run(cmd_gen(params, @filename))
      parse_output
    else
      raise MiniExiftool::Error.new(@error_text)
    end
    self
  end

  # Reload the tags of an already read file.
  def reload
    load @filename
  end

  # Returns the value of a tag.
  def [] tag
    @changed_values[tag] || @values[tag]
  end

  # Set the value of a tag.
  def []= tag, val
    @changed_values[tag] = val
  end

  # Returns true if any tag value is changed or if the value of a
  # given tag is changed.
  def changed? tag=false
    if tag
      @changed_values.include? tag
    else
      !@changed_values.empty?
    end
  end

  # Revert all changes or the change of a given tag.
  def revert tag=nil
    if tag
      val = @changed_values.delete(tag)
      res = val != nil
    else
      res = @changed_values.size > 0
      @changed_values.clear
    end
    res
  end

  # Returns an array of the tags (original tag names) of the read file.
  def tags
    @values.keys.map { |key| @tag_names[key] }
  end

  # Returns an array of all changed tags.
  def changed_tags
    @changed_values.keys.map { |key| MiniExiftool.original_tag(key) }
  end

  # Save the changes to the file.
  def save
    MiniExiftool.setup
    return false if @changed_values.empty?
    @errors.clear
    temp_file = Tempfile.new('mini_exiftool')
    temp_file.close
    temp_filename = temp_file.path
    FileUtils.cp filename.encode(@@fs_enc), temp_filename
    all_ok = true
    @changed_values.each do |tag, val|
      original_tag = MiniExiftool.original_tag(tag)
      arr_val = val.kind_of?(Array) ? val : [val]
      arr_val.map! {|e| convert_before_save(e)}
      params = '-q -P -overwrite_original '
      params << (arr_val.detect {|x| x.kind_of?(Numeric)} ? '-n ' : '')
      params << (@ignore_minor_errors ? '-m ' : '')
      arr_val.each do |v|
        params << %Q(-#{original_tag}=#{escape(v)} )
      end
      result = run(cmd_gen(params, temp_filename))
      unless result
        all_ok = false
        @errors[tag] = @error_text.gsub(/Nothing to do.\n\z/, '').chomp
      end
    end
    if all_ok
      FileUtils.cp temp_filename, filename.encode(@@fs_enc)
      reload
    end
    temp_file.delete
    all_ok
  end

  def save!
    unless save
      err = []
      self.errors.each do |key, value|
        err << "(#{key}) #{value}"
      end
      raise MiniExiftool::Error.new("MiniExiftool couldn't save. The following errors occurred: #{err.empty? ? "None" : err.join(", ")}")
    end
  end

  # Returns a hash of the original loaded values of the MiniExiftool
  # instance.
  def to_hash
    result = {}
    @values.each do |k,v|
      result[@tag_names[k]] = v
    end
    result
  end

  # Returns a YAML representation of the original loaded values of the
  # MiniExiftool instance.
  def to_yaml
    to_hash.to_yaml
  end

  # Create a MiniExiftool instance from a hash. Default value
  # conversions will be applied if neccesary.
  def self.from_hash hash
    instance = MiniExiftool.new
    instance.initialize_from_hash hash
    instance
  end

  # Create a MiniExiftool instance from JSON data. Default value
  # conversions will be applied if neccesary.
  def self.from_json json, opts={}
    instance = MiniExiftool.new nil, opts
    instance.initialize_from_json json
    instance
  end

  # Create a MiniExiftool instance from YAML data created with
  # MiniExiftool#to_yaml
  def self.from_yaml yaml
    MiniExiftool.from_hash YAML.load(yaml)
  end

  # Returns the command name of the called Exiftool application.
  def self.command
    @@cmd
  end

  # Setting the command name of the called Exiftool application.
  def self.command= cmd
    @@cmd = cmd
  end

  # Returns the options hash.
  def self.opts
    @@opts
  end

  # Returns a set of all known tags of Exiftool.
  def self.all_tags
    unless defined? @@all_tags
      @@all_tags = pstore_get :all_tags
    end
    @@all_tags
  end

  # Returns a set of all possible writable tags of Exiftool.
  def self.writable_tags
    unless defined? @@writable_tags
      @@writable_tags = pstore_get :writable_tags
    end
    @@writable_tags
  end

  # Returns the original Exiftool name of the given tag
  def self.original_tag tag
    unless defined? @@all_tags_map
      @@all_tags_map = pstore_get :all_tags_map
    end
    @@all_tags_map[tag]
  end

  # Returns the version of the Exiftool command-line application.
  def self.exiftool_version
    output = `#{MiniExiftool.command} -ver 2>&1`
    unless $?.exitstatus == 0
      raise MiniExiftool::Error.new("Command '#{MiniExiftool.command}' not found")
    end
    output.chomp!
  end

  def self.unify tag
    tag.to_s.gsub(/[-_]/,'').downcase
  end

  # Exception class
  class MiniExiftool::Error < StandardError; end

  ############################################################################
  private
  ############################################################################

  @@setup_done = false
  def self.setup
    return if @@setup_done
    @@error_file = Tempfile.new 'errors'
    @@error_file.close
    @@setup_done = true
  end

  def cmd_gen arg_str='', filename
    [@@cmd, arg_str.encode('UTF-8'), escape(filename.encode(@@fs_enc))].map {|s| s.force_encoding('UTF-8')}.join(' ')
  end

  def run cmd
    if $DEBUG
      $stderr.puts cmd
    end
    @output = `#{cmd} 2>#{@@error_file.path}`
    @status = $?
    unless @status.exitstatus == 0
      @error_text = File.readlines(@@error_file.path).join
      @error_text.force_encoding('UTF-8')
      return false
    else
      @error_text = ''
      return true
    end
  end

  def convert_before_save val
    case val
    when Time
      val = val.strftime('%Y:%m:%d %H:%M:%S')
    end
    val
  end

  def method_missing symbol, *args
    tag_name = symbol.id2name
    if tag_name.sub!(/=$/, '')
      self[tag_name] = args.first
    else
      self[tag_name]
    end
  end

  def parse_output
    @output.force_encoding('UTF-8')
    if @replace_invalid_chars && !@output.valid_encoding?
      @output.encode!('UTF-16le', invalid: :replace, replace: @replace_invalid_chars).encode!('UTF-8')
    end
    JSON.parse(@output)[0].each do |tag,value|
      value = convert_after_load(value)
      set_value tag, value
    end
  end

  def convert_after_load value
    return value unless value.kind_of?(String)
    case value
    when /^\d{4}:\d\d:\d\d \d\d:\d\d:\d\d/
      s = value.sub(/^(\d+):(\d+):/, '\1-\2-')
      begin
        if @timestamps == Time
          value = Time.parse(s)
        elsif @timestamps == DateTime
          value = DateTime.parse(s)
        else
          raise MiniExiftool::Error.new("Value #@timestamps not allowed for option timestamps.")
        end
      rescue ArgumentError
        value = false
      end
    when /^\+\d+\.\d+$/
      value = value.to_f
    when /^0+[1-9]+$/
      # nothing => String
    when /^-?\d+$/
      value = value.to_i
    when %r(^(\d+)/(\d+)$)
      value = Rational($1.to_i, $2.to_i)
    when /^[\d ]+$/
      # nothing => String
    end
    value
  end

  def set_value tag, value
    @tag_names[tag] = tag
    @values[tag] = value
  end

  def set_attributes_by_heuristic
    self.composite = tags.include?('ImageSize') ? true : false
    self.numerical = self.file_size.kind_of?(Integer) ? true : false
    self.timestamps = self.FileModifyDate.kind_of?(DateTime) ? DateTime : Time
  end

  def self.pstore_get attribute
    load_or_create_pstore unless defined? @@pstore
    result = nil
    @@pstore.transaction(true) do |ps|
      result = ps[attribute]
    end
    result
  end

  @@running_on_windows = /mswin|mingw|cygwin/ === RbConfig::CONFIG['host_os']

  def self.load_or_create_pstore
    # This will hopefully work on *NIX and Windows systems
    home = ENV['HOME'] || ENV['HOMEDRIVE'] + ENV['HOMEPATH'] || ENV['USERPROFILE']
    subdir = @@running_on_windows ? '_mini_exiftool' : '.mini_exiftool'
    FileUtils.mkdir_p(File.join(home, subdir))
    pstore_filename = File.join(home, subdir, 'exiftool_tags_' << exiftool_version.gsub('.', '_') << '.pstore')
    @@pstore = PStore.new pstore_filename
    if !File.exist?(pstore_filename) || File.size(pstore_filename) == 0
      @@pstore.transaction do |ps|
        ps[:all_tags] = all_tags = determine_tags('list')
        ps[:writable_tags] = determine_tags('listw')
        map = {}
        all_tags.each { |k| map[unify(k)] = k }
        ps[:all_tags_map] = map
      end
    end
  end

  def self.determine_tags arg
    output = `#{@@cmd} -#{arg}`
    lines = output.split(/\n/)
    tags = Set.new
    lines.each do |line|
      next unless line =~ /^\s/
      tags |= line.chomp.split
    end
    tags
  end

  if @@running_on_windows
    def escape val
      '"' << val.to_s.gsub(/([\\"])/, "\\\\\\1") << '"'
    end
  else
    def escape val
      '"' << val.to_s.gsub(/([\\"$])/, "\\\\\\1") << '"'
    end
  end

  # Hash with indifferent access:
  # DateTimeOriginal == datetimeoriginal == date_time_original
  class TagHash < Hash # :nodoc:
    def[] k
      super(unify(k))
    end
    def []= k, v
      super(unify(k), v)
    end
    def delete k
      super(unify(k))
    end

    def unify tag
      MiniExiftool.unify tag
    end
  end

end
