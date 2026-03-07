# frozen_string_literal: true

require "rss"
require "json"
require "http"
require "time"
require "cgi"

JST = "+09:00"

RSS_URLS = [
  # 海外AIニュース
  "https://techcrunch.com/tag/artificial-intelligence/feed/",
  "https://venturebeat.com/category/ai/feed/",
  "https://www.theverge.com/rss/ai/index.xml",
  "https://www.technologyreview.com/topic/artificial-intelligence/feed",

  # 技術寄り
  "https://feeds.arstechnica.com/arstechnica/technology-lab",
  "https://github.blog/feed/",

  # 公式
  "https://openai.com/blog/rss.xml",
  "https://raw.githubusercontent.com/taobojlen/anthropic-rss-feed/main/anthropic_news_rss.xml",
  "https://blog.google/technology/ai/rss/",

  # 日本
  "https://rss.itmedia.co.jp/rss/2.0/news_ai.xml",
  "https://www.publickey1.jp/atom.xml",
  "https://gigazine.net/news/rss_2.0/"
]

KEYWORDS = %w[OpenAI Google Anthropic LLM GPT Gemini Claude Meta Microsoft].freeze
GEMINI_MODEL = ENV.fetch("GEMINI_MODEL", "gemini-2.0-flash")
AI_RELEVANCE_PATTERNS = [
  /(^|[^a-z])ai([^a-z]|$)/i,
  /人工知能|生成AI|生成ai|機械学習|深層学習|大規模言語モデル|LLM|llm/i,
  /OpenAI|Anthropic|Gemini|Claude|GPT|Copilot|DeepSeek|Mistral|Llama|Perplexity/i,
  /画像生成|音声生成|動画生成|RAG|エージェント|推論|推論モデル|ファインチューニング/i
].freeze

# =========================================
# Orchestration
# =========================================
def run
  from_time, to_time = day_window_jst

  articles = fetch_articles(RSS_URLS, from_time, to_time)
  articles = deduplicate_articles(articles)

  add_scores(articles)
  top_articles = pick_top_articles(articles, limit: 10)

  selected = gemini_select(top_articles)
  final_articles = resolve_selected_articles(selected, top_articles)

  # 件数不足時は上位候補から補充（重複除外）
  if final_articles.length < 5
    used_links = final_articles.map { |a| a[:link] }
    refill = top_articles.reject { |a| used_links.include?(a[:link]) }
                         .first(5 - final_articles.length)
    final_articles.concat(refill)
  end

  # 要約生成（タイトルとリンクをもとにまとめて1回）
  summaries = generate_summaries(final_articles)
  final_articles.each_with_index do |article, idx|
    article[:summary] = summaries[idx] || build_local_fallback_summary(article)
  end

  if final_articles.empty?
    warn "[INFO] No publishable articles for this run. Slack post skipped."
    return
  end

  post_to_slack(final_articles)
end

private

# =========================================
# Time Window (JST stateless)
# =========================================
def day_window_jst
  now = Time.now.getlocal(JST)
  today_midnight = Time.new(now.year, now.month, now.day, 0, 0, 0, JST)
  yesterday_midnight = today_midnight - 86_400
  [yesterday_midnight, today_midnight]
end

# =========================================
# RSSフィードを巡回し、指定したJST時間窓内の記事かつAI_RELEVANCE_PATTERNSに該当したものを収集して返す
# =========================================
def fetch_articles(urls, from_time, to_time)
  articles = []

  urls.each do |url|
    begin
      rss_xml = HTTP
                .headers("User-Agent" => "Mozilla/5.0 (compatible; AI-News-Bot/1.0)")
                .timeout(connect: 8, read: 12, write: 8)
                .follow(max_hops: 5)
                .get(url)
                .to_s
      rss = RSS::Parser.parse(rss_xml.force_encoding("UTF-8"), false)
    rescue => e
      warn "[RSS ERROR] #{url} #{e.message}"
      next
    end

    rss.items.each do |item|
      begin
        next unless item.respond_to?(:pubDate) && item.pubDate

        pub_time = Time.parse(item.pubDate.to_s).getlocal(JST)
        next unless pub_time >= from_time && pub_time < to_time

        title = clean_text(item.title.to_s)
        categories = if item.respond_to?(:categories) && item.categories
                       item.categories.map(&:to_s).join(" ")
                     else
                       ""
                     end
        source_text = [title, categories].join(" ")
        # AI特化ソースURLか本文のAI関連キーワードのどちらかに該当した記事のみ残す
        ai_focused_source = url.match?(/artificial-intelligence|\/ai\/|news_ai|technology\/ai|openai\.com\/blog\/rss|anthropic\.com\/news\/rss/i)
        next if !ai_focused_source && !ai_related_text?(source_text)

        articles << {
          title: title,
          link: item.link.to_s,
          published: pub_time
        }
      rescue => e
        warn "[RSS ITEM ERROR] #{url} #{e.message}"
        next
      end
    end
  end

  articles
end

# nbsp等の不要な文字列を削除
def clean_text(raw)
  return "" if raw.nil? || raw.empty?

  raw = raw.encode("UTF-8", invalid: :replace, undef: :replace)

  text = raw
           .gsub(/<\/?[^>]*>/, " ")
  2.times { text = CGI.unescapeHTML(text) }
  text = text.gsub(/&(nbsp|#160|#xA0);/i, " ")
  text = text.gsub(/\u00A0/, " ")
  text = text.gsub(/\s+/, " ").strip

  text
end

def ai_related_text?(text)
  t = text.to_s
  AI_RELEVANCE_PATTERNS.any? { |pattern| t.match?(pattern) }
end

# =========================================
# スコア付け（タイトル内のキーワード一致数で優先度を決める）
# =========================================
def add_scores(articles)
  articles.each do |article|
    article[:score] = KEYWORDS.count { |k| article[:title].include?(k) }
  end
end

def pick_top_articles(articles, limit: 10)
  articles.sort_by { |a| -a[:score] }.first(limit)
end

# 
def gemini_select(articles)
  return [] if articles.empty?

  raw = call_gemini(build_selection_prompt(articles))

  json_text = raw[/\[[\s\S]*\]/]
  JSON.parse(json_text)
rescue
  articles.first(5).map.with_index(1) { |a, i| { "index" => i, "title" => a[:title] } }
end

# =========================================
# Gemini: 意味重複排除 + 5件選定
# =========================================
def build_selection_prompt(articles)
  <<~TEXT
    以下のニュースタイトルがあります。
    内容が実質同じニュースは1つにまとめ、
    重要なものを5件選び、
    JSON配列のみで返してください。

    [
      {"index": 1, "title": "..."}
    ]

    #{articles.map.with_index(1) { |a, i| "#{i}. #{a[:title]}" }.join("\n")}
  TEXT
end

# =========================================
# Geminiの選定結果（index/title）を候補記事配列に解決し、最後に重複を除去する
# =========================================
def resolve_selected_articles(selected, candidates)
  resolved = selected.map do |sel|
    idx = sel["index"].to_i
    if idx.positive? && idx <= candidates.length
      candidates[idx - 1]
    else
      # indexが壊れている/欠けている場合は、正規化タイトル一致で候補を探す
      wanted = normalize_title(sel["title"])
      candidates.find { |a| normalize_title(a[:title]) == wanted }
    end
  end.compact

  deduplicate_articles(resolved)
end

# =========================================
# Gemini: 要約生成
# =========================================
def generate_summaries(articles)
  return {} if articles.empty?

  raw = call_gemini(build_batch_summary_prompt(articles))
  summaries = parse_summary_lines(raw, articles.length)
  summaries
rescue
  {}
end

def build_batch_summary_prompt(articles)
  blocks = articles.map.with_index(1) do |article, idx|
    <<~TEXT
      [#{idx}]
      タイトル: #{article[:title]}
      リンク: #{article[:link]}
      ---
    TEXT
  end.join("\n")

  <<~TEXT
    次のニュース情報（タイトル・リンク先に遷移した際の内容）をもとに、各記事の要点を日本語で短く作成してください。
    要約は80〜120文字を目安に、1〜2文で完結してください。
    必ず「。」で終わらせてください。
    タイトルの言い換えは禁止。
    固有名詞・数字・変更点を優先。
    曖昧表現は禁止。
    媒体名・著者名・配信日時などのメタ情報は禁止。
    英語は禁止。日本語のみ。
    「...」「…」は禁止。
    出力形式は必ず次の行形式のみ（前置き禁止・コードブロック禁止）。

    1|要約
    2|要約
    3|要約

    #{blocks}
  TEXT
end

def build_local_fallback_summary(article, max_length: 120)
  title = clean_text(article[:title].to_s)
  concise = "#{title}に関する更新です。詳細はリンク先でご確認ください。"
  sanitize_summary_text(concise, max_length: max_length)
end

def parse_summary_lines(raw, size)
  summaries = {}
  raw.to_s.each_line do |line|
    matched = line.strip.match(/\A(\d{1,2})\s*\|\s*(.+)\z/)
    next unless matched

    idx = matched[1].to_i
    next if idx <= 0 || idx > size

    summary = sanitize_summary_text(matched[2].to_s, max_length: 120)
    next if summary.empty? || !japanese_text?(summary)

    summaries[idx - 1] = summary
  end
  summaries
end

def sanitize_summary_text(text, max_length: 140)
  cleaned = clean_text(text.to_s)
  cleaned = cleaned.gsub(/\.\.\.+/, "")
  cleaned = cleaned.gsub(/…+/, "")
  cleaned = cleaned.gsub(/\s+/, " ").strip

  return cleaned if cleaned.length <= max_length

  # 文単位で自然に収める
  sentences = cleaned.split(/(?<=[。！？])/)

  result = ""
  sentences.each do |sentence|
    break if (result + sentence).length > max_length
    result += sentence
  end

  # もし何も入らなかったら強制カット
  result = cleaned[0...max_length] if result.strip.empty?

  result.strip
end

def japanese_text?(text)
  text.to_s.match?(/[ぁ-んァ-ン一-龥]/)
end

# =========================================
# 重複除去（タイトルを正規化して同一記事を1件にまとめる）
# =========================================
def deduplicate_articles(articles)
  seen = {}
  articles.reject do |article|
    key = normalize_title(article[:title])
    seen[key] ? true : (seen[key] = true; false)
  end
end

def normalize_title(text)
  text.to_s.downcase.gsub(/[^a-z0-9ぁ-んァ-ン一-龥]/, "")
end

# =========================================
# Gemini Common Caller
# =========================================
def call_gemini(prompt)
  api_key = ENV["GEMINI_API_KEY"]
  raise "GEMINI_API_KEY missing" if api_key.to_s.empty?

  response = HTTP.post(
    "https://generativelanguage.googleapis.com/v1beta/models/#{GEMINI_MODEL}:generateContent?key=#{api_key}",
    json: {
      contents: [{ parts: [{ text: prompt }] }],
      generationConfig: {
        temperature: 0.2,
        maxOutputTokens: 2000
      }
    }
  )

  result = JSON.parse(response.body.to_s)
  result.dig("candidates", 0, "content", "parts", 0, "text").to_s
rescue => e
  warn "[Gemini ERROR] #{e.message}"
  ""
end

# =========================================
# Slack Output
# =========================================
def post_to_slack(articles)
  webhook = ENV["SLACK_WEBHOOK_URL"]
  raise "SLACK_WEBHOOK_URL missing" if webhook.to_s.empty?

  blocks = build_slack_blocks(articles)
  res = HTTP.post(webhook, json: { blocks: blocks })
  warn "[Slack ERROR] status=#{res.status}" unless res.status.success?
  res.status.success?
end

def build_slack_blocks(articles)
  [
    {
      type: "section",
      text: {
        type: "mrkdwn",
        text: build_slack_text(articles, mention: "<!here>")
      }
    }
  ]
end

def build_slack_text(articles, mention: nil)
  lines = []
  date_str = Time.now.getlocal(JST).strftime("%-m/%-d")

  lines << mention if mention
  lines << "🧠 *#{date_str}のAIニュース*"
  lines << ""

  articles.each_with_index do |article, i|
    lines << "#{i + 1}. *#{article[:title]}*"
    lines << "   👉 #{article[:summary]}"
    lines << "   🔗 <#{article[:link]}|続きを読む>"
    lines << ""
  end

  lines.join("\n")
end

run
