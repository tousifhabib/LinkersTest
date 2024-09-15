require 'test/unit'
require 'csv'
require 'json'
require_relative 'main'

ENV['RUBY_ENV'] = 'test'
TEST_CONFIG = JSON.parse(File.read('config.json'))['test']

class TestAddressSearch < Test::Unit::TestCase
  class << self
    def startup
      @storage = PickleStorage.new
      @searcher = AddressSearcher.new(@storage)

      original_log_level = @searcher.instance_variable_get(:@logger).level
      begin
        @searcher.instance_variable_get(:@logger).level = Logger::WARN
        @addresses = load_test_addresses
        @index = @searcher.build_inverted_index(@addresses)
      ensure
        @searcher.instance_variable_get(:@logger).level = original_log_level
      end
    end

    def load_test_addresses
      CSV.read(TEST_CONFIG['csv_path'], headers: true).map do |row|
        AddressData.new(*row.fields.map(&:to_s).map(&:strip))
      end
    end
  end

  def test_2gram_generation
    assert_equal(%w[東京 京都], self.class.instance_variable_get(:@searcher).generate_2grams("東京都"))
    assert_equal(%w[きょ ょう うと], self.class.instance_variable_get(:@searcher).generate_2grams("きょうと"))
    assert_equal(%w[きょ ょう うと], self.class.instance_variable_get(:@searcher).generate_2grams("キョウト"))
  end

  def test_search_single_token
    results = self.class.instance_variable_get(:@searcher).search("渋谷", self.class.instance_variable_get(:@index), self.class.instance_variable_get(:@addresses))
    assert_equal(4, results.length)
    assert results.all? { |r| r.full_address.include?("渋谷") }
  end

  def test_search_multiple_tokens
    results = self.class.instance_variable_get(:@searcher).search("東京都渋谷", self.class.instance_variable_get(:@index), self.class.instance_variable_get(:@addresses))
    assert_equal(1, results.length)
    assert results.all? { |r| r.prefecture == "東京都" && r.full_address.include?("渋谷") }
  end

  def test_search_no_results
    results = self.class.instance_variable_get(:@searcher).search("名古屋", self.class.instance_variable_get(:@index), self.class.instance_variable_get(:@addresses))
    assert_equal(0, results.length)
  end

  def test_search_shibuya_office
    results = self.class.instance_variable_get(:@searcher).search("東京都渋谷都税事務所", self.class.instance_variable_get(:@index), self.class.instance_variable_get(:@addresses))
    assert_equal(1, results.length)
    assert_equal("東京都渋谷都税事務所", results.first.business_name)
  end

  def test_search_tokyo
    results = self.class.instance_variable_get(:@searcher).search("東京都", self.class.instance_variable_get(:@index), self.class.instance_variable_get(:@addresses))
    assert results.any? { |r| r.prefecture == "東京都" }
    assert results.all? { |r| r.full_address.include?("東京") || r.full_address.include?("とうきょうと") }
  end

  def test_search_katakana_tokyo
    results = self.class.instance_variable_get(:@searcher).search("トウキョウト", self.class.instance_variable_get(:@index), self.class.instance_variable_get(:@addresses))
    assert_equal(2, results.length)
    assert results.any? { |r| r.prefecture == "トウキョウト" }
  end

  def test_search_hiragana_tokyo
    results = self.class.instance_variable_get(:@searcher).search("とうきょうと", self.class.instance_variable_get(:@index), self.class.instance_variable_get(:@addresses))
    assert_equal(2, results.length)
    assert results.any? { |r| r.prefecture == "とうきょうと" }
  end

  def test_search_katakana_osaka
    results = self.class.instance_variable_get(:@searcher).search("オオサカフ", self.class.instance_variable_get(:@index), self.class.instance_variable_get(:@addresses))
    assert_equal(2, results.length)
    assert results.any? { |r| r.prefecture == "オオサカフ" }
  end

  def test_search_hiragana_osaka
    results = self.class.instance_variable_get(:@searcher).search("おおさかふ", self.class.instance_variable_get(:@index), self.class.instance_variable_get(:@addresses))
    assert_equal(2, results.length)
    assert results.any? { |r| r.prefecture == "おおさかふ" }
  end

  def test_search_tokyo_and_kyoto
    results = self.class.instance_variable_get(:@searcher).search("東京都京都", self.class.instance_variable_get(:@index), self.class.instance_variable_get(:@addresses))
    assert_equal(9, results.length)
    assert results.any? { |r| r.kyoto_street&.include?("京都") || r.business_name&.include?("京都") }
  end

  def test_search_kyoto_not_in_tokyo
    results = self.class.instance_variable_get(:@searcher).search("東京都", self.class.instance_variable_get(:@index), self.class.instance_variable_get(:@addresses))
    refute results.any? { |r| r.prefecture == "京都府" }
  end

  def test_search_tokyo_in_other_prefecture
    results = self.class.instance_variable_get(:@searcher).search("東京", self.class.instance_variable_get(:@index), self.class.instance_variable_get(:@addresses))
    tokyo_elsewhere = results.select { |r| r.prefecture != "東京都" && r.full_address.include?("東京") }
    assert_equal(2, tokyo_elsewhere.length)
    assert_includes %w[鹿児島県 千葉県], tokyo_elsewhere.first.prefecture
  end

  def test_search_kyoto_street_in_tokyo
    results = self.class.instance_variable_get(:@searcher).search("東京都京都通り", self.class.instance_variable_get(:@index), self.class.instance_variable_get(:@addresses))
    assert_equal(2, results.length)
    assert(results.all? { |r| r.prefecture == "東京都" && r.kyoto_street == "京都通り" })
    assert(results.any? { |r| r.city == "新宿区" })
  end

  def test_search_kyoto_street_case_insensitive
    results_kanji = self.class.instance_variable_get(:@searcher).search("東京都京都通り", self.class.instance_variable_get(:@index), self.class.instance_variable_get(:@addresses))
    results_hiragana = self.class.instance_variable_get(:@searcher).search("とうきょうときょうとどおり", self.class.instance_variable_get(:@index), self.class.instance_variable_get(:@addresses))
    results_katakana = self.class.instance_variable_get(:@searcher).search("トウキョウトキョウトドオリ", self.class.instance_variable_get(:@index), self.class.instance_variable_get(:@addresses))
    assert_equal(results_kanji.length, results_hiragana.length)
    assert_equal(results_kanji.length, results_katakana.length)
  end

  def test_search_partial_match_street
    results = self.class.instance_variable_get(:@searcher).search("京都街", self.class.instance_variable_get(:@index), self.class.instance_variable_get(:@addresses))
    assert_equal(1, results.length)
    assert_equal("東京都", results.first.prefecture)
    assert_equal("京都街", results.first.kyoto_street)
  end

  def test_search_exact_match_priority
    results = self.class.instance_variable_get(:@searcher).search("京都", self.class.instance_variable_get(:@index), self.class.instance_variable_get(:@addresses))
    assert_equal("京都府", results.first.prefecture)
    assert results.any? { |r| r.prefecture == "東京都" && r.kyoto_street&.include?("京都") }
  end

  def test_search_multiple_kyoto_references
    results = self.class.instance_variable_get(:@searcher).search("東京都京都通京都タワー", self.class.instance_variable_get(:@index), self.class.instance_variable_get(:@addresses))
    assert_equal(1, results.length)
    assert_equal("東京都", results.first.prefecture)
    assert_equal("京都通り", results.first.kyoto_street)
    assert_equal("京都タワー商事", results.first.business_name)
  end
end
