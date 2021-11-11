# -- encoding: utf-8 --
require 'digest/md5'
require 'fileutils'
require 'tempfile'
require 'helpers_for_test'

class TestSave < TestCase
  include TempfileTest

  def setup
    super
    @org_filename = File.join(@data_dir, 'test.jpg')
    FileUtils.cp(@org_filename, @temp_filename)
    @mini_exiftool = MiniExiftool.new @temp_filename
    @mini_exiftool_num = MiniExiftool.new @temp_filename, numerical: true
    @org_md5 = Digest::MD5.hexdigest(File.read(@org_filename))
  end

  def test_clear_all_tags
    before_tags_count = @mini_exiftool_num.tags
    result = @mini_exiftool_num.clear_all_tags
    assert_equal true, result
    assert_equal @org_md5, Digest::MD5.hexdigest(File.read(@org_filename))
    assert_not_equal @org_md5, Digest::MD5.hexdigest(File.read(@temp_filename))
    assert_equal false, @mini_exiftool_num.changed?
    assert_not_equal before_tags_count, @mini_exiftool_num.tags
  end
end
