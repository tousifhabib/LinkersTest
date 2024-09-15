require 'bundler/setup'
require 'csv'
require 'set'
require 'optparse'
require 'json'
require 'msgpack'
require 'moji'
require 'logger'

CONFIG = JSON.parse(File.read('config.json'))[ENV['RUBY_ENV'] || 'default']

module Storage
  def save(data, filename)
    File.open(filename, 'wb') { |file| file.write(MessagePack.pack(data)) }
  end

  def load(filename)
    MessagePack.unpack(File.read(filename))
  end
end

class PickleStorage
  include Storage
end

# 住所データを表すクラス
class AddressData
  attr_reader :postal_code, :prefecture, :city, :town_area,
              :kyoto_street, :block_number, :business_name, :business_address

  def initialize(postal_code, prefecture, city, town_area, kyoto_street,
                 block_number, business_name, business_address)
    @postal_code = postal_code
    @prefecture = prefecture
    @city = city
    @town_area = town_area
    @kyoto_street = kyoto_street
    @block_number = block_number
    @business_name = business_name
    @business_address = business_address
  end

  # 完全な住所を生成
  def full_address
    @full_address ||= [
      prefecture, city, town_area, kyoto_street, block_number,
      business_name, business_address
    ].compact.reject(&:empty?).join(' ')
  end

  # フォーマットされた出力を生成
  def formatted_output
    "#{postal_code} #{full_address}"
  end

  def to_a
    [
      postal_code, prefecture, city, town_area, kyoto_street,
      block_number, business_name, business_address
    ]
  end
end

# 住所検索を行うクラス
class AddressSearcher
  def initialize(storage)
    @storage = storage
    @logger = Logger.new(STDOUT)
    @logger.level = Logger::INFO
  end

  # テキストを正規化する
  def normalize(text)
    Moji.kata_to_hira(text.to_s.unicode_normalize(:nfkc).downcase)
  end

  # 2-gramを生成する
  # @param text [String] 入力テキスト
  # @return [Array<String>] 2-gramの配列
  def generate_2grams(text)
    chars = normalize(text).chars
    (0...chars.length - 1).map { |i| chars[i..i + 1].join }
  end

  # 転置インデックスを構築する
  # @param addresses [Array<AddressData>] 住所データの配列
  # @return [Hash] 転置インデックス
  def build_inverted_index(addresses)
    index = Hash.new { |h, k| h[k] = Set.new }
    addresses.each_with_index do |address, idx|
      searchable_fields = [
        address.prefecture, address.city, address.town_area,
        address.kyoto_street, address.block_number,
        address.business_name, address.business_address
      ].compact.reject(&:empty?)

      searchable_fields.each do |field|
        generate_2grams(field).each { |gram| index[gram].add(idx) }
      end
    end
    @logger.info "インデックスには#{index.size}個のユニークな2グラムが含まれています。"
    index.transform_values(&:to_a) # SetをArrayに変換
  end

  # 住所を検索する
  # @param query [String] 検索クエリ
  # @param index [Hash] 転置インデックス
  # @param addresses [Array<AddressData>] 住所データの配列
  # @return [Array<AddressData>] 検索結果の配列
  def search(query, index, addresses)
    @logger.info "検索クエリ: #{query}"
    query_grams = generate_2grams(query).uniq

    present_grams = query_grams & index.keys
    return [] if present_grams.empty?

    address_sets = present_grams.map { |gram| index[gram] }
    results_indices = address_sets.reduce(:&)
    results = results_indices.map { |idx| addresses[idx] }

    @logger.info "#{results.length}件の結果が見つかりました。"
    results.sort_by { |address| -address.full_address.count(query) }
  end
end

# CSVファイルから住所データを読み込む
def load_csv(file_path)
  CSV.read(file_path, encoding: CONFIG['encoding'], headers: true).map do |row|
    AddressData.new(
      row['郵便番号']&.strip || '',
      row['都道府県']&.strip || '',
      row['市区町村']&.strip || '',
      row['町域']&.strip,
      row['京都通り名']&.strip,
      row['字丁目']&.strip,
      row['事業所名']&.strip,
      row['事業所住所']&.strip
    )
  end
end

def main
  options = {}
  OptionParser.new do |opts|
    opts.on('--build', 'インデックスを構築する') { options[:build] = true }
    opts.on('--search QUERY', '住所を検索する') { |v| options[:search] = v }
    opts.on('--csv_path PATH', 'CSVファイルのパス') { |v| options[:csv_path] = v }
    opts.on('--index_path PATH', 'インデックスを保存/読み込むパス') { |v| options[:index_path] = v }
    opts.on('--addresses_path PATH', '住所データを保存/読み込むパス') { |v| options[:addresses_path] = v }
  end.parse!

  options[:csv_path] ||= CONFIG['csv_path']
  options[:index_path] ||= CONFIG['index_path']
  options[:addresses_path] ||= CONFIG['addresses_path']

  storage = PickleStorage.new
  searcher = AddressSearcher.new(storage)

  if options[:build]
    build_index(options, storage, searcher)
  elsif options[:search]
    perform_search(options, storage, searcher)
  else
    puts "必ず --build または --search のオプションを指定してください。"
  end
end

# インデックスを構築する
def build_index(options, storage, searcher)
  logger = Logger.new(STDOUT)
  logger.level = Logger::INFO

  logger.info "インデックスの構築を開始します。"
  start_time = Time.now

  addresses = load_csv(options[:csv_path])
  index = searcher.build_inverted_index(addresses)
  storage.save(index, options[:index_path])
  storage.save(addresses.map(&:to_a), options[:addresses_path])

  end_time = Time.now
  duration = end_time - start_time
  logger.info "インデックスを構築し、#{options[:index_path]}に保存しました。所要時間: #{(duration * 1000).round(2)}ミリ秒"
  logger.info "住所データを#{options[:addresses_path]}に保存しました。"
end

# 検索を実行する
def perform_search(options, storage, searcher)
  logger = Logger.new(STDOUT)
  logger.level = Logger::INFO

  unless File.exist?(options[:index_path]) && File.exist?(options[:addresses_path])
    logger.error "転置インデックスまたは住所データファイルが見つかりません。先にインデックスを構築してください。"
    return
  end

  index = storage.load(options[:index_path])
  addresses = storage.load(options[:addresses_path]).map { |addr| AddressData.new(*addr) }

  start_time = Time.now
  results = searcher.search(options[:search], index, addresses)
  end_time = Time.now
  duration = end_time - start_time

  if results.any?
    results.each { |result| puts result.formatted_output }
  else
    puts "結果が見つかりませんでした。"
  end

  logger.info "検索が完了しました。所要時間: #{(duration * 1000).round(2)}ミリ秒"
end

main if __FILE__ == $0